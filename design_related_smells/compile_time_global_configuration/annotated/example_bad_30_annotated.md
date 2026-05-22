# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@stripe_base_url` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `create_payment_intent/2`, `capture_payment_intent/1`, `cancel_payment_intent/1`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to resolve the Stripe base URL and assign it to `@stripe_base_url`. During Mix compilation the application has not started, so Elixir raises an `ArgumentError` or a compiler warning. The URL is embedded in the compiled beam, which makes pointing the client at a test or staging endpoint at runtime impossible without recompiling.

---

```elixir
defmodule Payments.StripeClient do
  @moduledoc """
  Low-level HTTP client for the Stripe Payments API.
  Handles PaymentIntent lifecycle: create, capture, and cancel.
  Authentication is via Bearer token; the base URL is configurable
  to support sandbox and live environments.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 runs at module
  # VALIDATION: compilation time, before the :payments application is loaded.
  # VALIDATION: Elixir will raise or warn:
  # VALIDATION:   warning: Application.fetch_env!/2 is discouraged in the
  # VALIDATION:   module body, use Application.compile_env/3 instead
  # VALIDATION: Switching between live and sandbox URLs also requires a
  # VALIDATION: full recompile because the string is baked into the beam.
  @stripe_base_url Application.fetch_env!(:payments, :stripe_base_url)
  # VALIDATION: SMELL END

  @api_version "2023-10-16"
  @request_timeout_ms 15_000
  @idempotency_ttl_hours 24

  @type money :: %{amount: non_neg_integer(), currency: String.t()}

  @type payment_intent :: %{
          id: String.t(),
          status: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          client_secret: String.t()
        }

  @spec create_payment_intent(money(), keyword()) ::
          {:ok, payment_intent()} | {:error, atom()}
  def create_payment_intent(%{amount: amount, currency: currency}, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_idempotency_key())
    capture_method = Keyword.get(opts, :capture_method, "automatic")

    body = %{
      amount: amount,
      currency: String.downcase(currency),
      capture_method: capture_method,
      payment_method_types: ["card"]
    }

    case post("/v1/payment_intents", body, idempotency_key: idempotency_key) do
      {:ok, %{"id" => id, "status" => status, "client_secret" => secret}} ->
        Logger.info("PaymentIntent created", id: id, amount: amount, currency: currency)

        {:ok,
         %{id: id, status: status, amount: amount, currency: currency, client_secret: secret}}

      {:error, %{"error" => %{"message" => msg}}} ->
        Logger.warning("PaymentIntent creation failed", reason: msg)
        {:error, :stripe_error}

      {:error, reason} ->
        Logger.error("Stripe request failed", reason: inspect(reason))
        {:error, :request_failed}
    end
  end

  @spec capture_payment_intent(String.t()) ::
          {:ok, payment_intent()} | {:error, atom()}
  def capture_payment_intent(payment_intent_id) when is_binary(payment_intent_id) do
    case post("/v1/payment_intents/#{payment_intent_id}/capture", %{}) do
      {:ok, %{"id" => id, "status" => status, "amount" => amount, "currency" => currency}} ->
        Logger.info("PaymentIntent captured", id: id, status: status)
        {:ok, %{id: id, status: status, amount: amount, currency: currency, client_secret: nil}}

      {:error, %{"error" => %{"code" => "payment_intent_unexpected_state"}}} ->
        {:error, :unexpected_state}

      {:error, _} ->
        {:error, :capture_failed}
    end
  end

  @spec cancel_payment_intent(String.t()) :: :ok | {:error, atom()}
  def cancel_payment_intent(payment_intent_id) when is_binary(payment_intent_id) do
    case post("/v1/payment_intents/#{payment_intent_id}/cancel", %{}) do
      {:ok, %{"status" => "canceled"}} ->
        Logger.info("PaymentIntent canceled", id: payment_intent_id)
        :ok

      {:error, %{"error" => %{"code" => "payment_intent_unexpected_state"}}} ->
        {:error, :unexpected_state}

      {:error, _} ->
        {:error, :cancel_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp post(path, body, opts \\ []) do
    url = @stripe_base_url <> path
    idempotency_key = Keyword.get(opts, :idempotency_key)
    secret_key = Application.fetch_env!(:payments, :stripe_secret_key)

    headers =
      [
        {"Authorization", "Bearer #{secret_key}"},
        {"Stripe-Version", @api_version},
        {"Content-Type", "application/x-www-form-urlencoded"}
      ]
      |> maybe_add_idempotency_header(idempotency_key)

    encoded_body = URI.encode_query(flatten_body(body))

    case http_client().post(url, encoded_body, headers, timeout: @request_timeout_ms) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %{body: resp_body}} ->
        {:error, Jason.decode!(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_idempotency_header(headers, nil), do: headers

  defp maybe_add_idempotency_header(headers, key),
    do: [{"Idempotency-Key", key} | headers]

  defp flatten_body(map, prefix \\ nil) do
    Enum.flat_map(map, fn {k, v} ->
      key = if prefix, do: "#{prefix}[#{k}]", else: to_string(k)

      case v do
        m when is_map(m) -> flatten_body(m, key)
        list when is_list(list) ->
          list |> Enum.with_index() |> Enum.flat_map(fn {el, i} ->
            flatten_body(%{i => el}, key)
          end)
        _ -> [{key, to_string(v)}]
      end
    end)
  end

  defp generate_idempotency_key do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp http_client, do: Application.get_env(:payments, :http_client, Payments.HttpClient)
end
```
