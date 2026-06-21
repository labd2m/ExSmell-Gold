# Annotated Bad Example 05

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@stripe_api_key` defined at the top of `Payments.StripeClient`
- **Affected function(s):** `create_payment_intent/2`, `confirm_payment_intent/2`, `cancel_payment_intent/1`
- **Short explanation:** `Application.fetch_env!/2` is invoked in the module body, causing the Stripe API key to be read from the Application Environment at compile-time. Since OTP application configuration is not guaranteed to be available during compilation, this can raise a warning or `ArgumentError`.

---

```elixir
defmodule Payments.StripeClient do
  @moduledoc """
  Thin wrapper around the Stripe v1 REST API for managing payment intents.
  Handles serialisation, authentication headers, and error normalisation.
  """

  require Logger

  @stripe_base_url "https://api.stripe.com/v1"
  @request_timeout 10_000

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called at the
  # VALIDATION: module level, binding the result to a module attribute at compile-time.
  # VALIDATION: If the :payments application configuration has not been loaded when the
  # VALIDATION: compiler processes this module, Elixir will raise a warning or ArgumentError.
  @stripe_api_key Application.fetch_env!(:payments, :stripe_api_key)
  # VALIDATION: SMELL END

  @type intent_params :: %{
          amount: pos_integer(),
          currency: String.t(),
          payment_method_types: [String.t()]
        }

  @type stripe_response :: {:ok, map()} | {:error, map()}

  @doc """
  Creates a PaymentIntent on Stripe.

  ## Parameters
    - `amount` - Amount in the smallest currency unit (e.g. cents for USD).
    - `params` - Map with `:currency` and optional `:payment_method_types`.
  """
  @spec create_payment_intent(pos_integer(), intent_params()) :: stripe_response()
  def create_payment_intent(amount, params) when is_integer(amount) and amount > 0 do
    currency = Map.get(params, :currency, "usd")
    methods = Map.get(params, :payment_method_types, ["card"])

    payload = %{
      amount: amount,
      currency: currency,
      payment_method_types: methods
    }

    Logger.info("Creating PaymentIntent amount=#{amount} currency=#{currency}")
    post("/payment_intents", payload)
  end

  @doc """
  Confirms a PaymentIntent, optionally attaching a payment method.

  ## Parameters
    - `intent_id` - The `pi_...` identifier returned by `create_payment_intent/2`.
    - `opts` - Optional map with `:payment_method` to attach.
  """
  @spec confirm_payment_intent(String.t(), map()) :: stripe_response()
  def confirm_payment_intent(intent_id, opts \\ %{}) when is_binary(intent_id) do
    Logger.info("Confirming PaymentIntent intent_id=#{intent_id}")
    post("/payment_intents/#{intent_id}/confirm", opts)
  end

  @doc """
  Cancels an uncaptured or incomplete PaymentIntent.

  ## Parameters
    - `intent_id` - The `pi_...` identifier to cancel.
  """
  @spec cancel_payment_intent(String.t()) :: stripe_response()
  def cancel_payment_intent(intent_id) when is_binary(intent_id) do
    Logger.info("Cancelling PaymentIntent intent_id=#{intent_id}")
    post("/payment_intents/#{intent_id}/cancel", %{})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp post(path, params) do
    url = @stripe_base_url <> path
    encoded = URI.encode_query(flatten_params(params))

    headers = [
      {"Authorization", "Bearer #{@stripe_api_key}"},
      {"Content-Type", "application/x-www-form-urlencoded"}
    ]

    case HTTPoison.post(url, encoded, headers, recv_timeout: @request_timeout) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %HTTPoison.Response{body: body}} ->
        decoded = Jason.decode!(body)
        error = get_in(decoded, ["error"]) || decoded
        Logger.error("Stripe API error path=#{path} type=#{error["type"]} message=#{error["message"]}")
        {:error, error}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP error path=#{path} reason=#{inspect(reason)}")
        {:error, %{"type" => "network_error", "message" => inspect(reason)}}
    end
  end

  defp flatten_params(params) when is_map(params) do
    Enum.map(params, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
```
