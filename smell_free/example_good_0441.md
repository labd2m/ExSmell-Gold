```elixir
defmodule Integrations.StripeClient do
  @moduledoc """
  A typed HTTP client for the Stripe API. All responses are decoded into
  domain structs so callers never pattern-match on raw maps. Network errors,
  HTTP error status codes, and Stripe API errors are each represented as
  distinct error tuples, enabling precise handling at the call site without
  inspecting raw response bodies.
  The client is stateless; configuration is read from the application
  environment on each call so credentials can be rotated without a restart.
  """

  alias Integrations.Stripe.{Charge, Customer, PaymentIntent}

  require Logger

  @base_url "https://api.stripe.com/v1"
  @request_timeout_ms 15_000
  @api_version "2023-10-16"

  @type stripe_error :: %{
          code: binary(),
          message: binary(),
          param: binary() | nil,
          type: binary()
        }

  @type client_error ::
          {:http_error, non_neg_integer(), stripe_error()}
          | {:network_error, term()}
          | {:decode_error, term()}

  # ---------------------------------------------------------------------------
  # Customers
  # ---------------------------------------------------------------------------

  @doc """
  Creates a Stripe customer and returns a typed `Customer` struct.
  """
  @spec create_customer(map()) :: {:ok, Customer.t()} | {:error, client_error()}
  def create_customer(attrs) when is_map(attrs) do
    post("/customers", attrs, &Customer.from_map/1)
  end

  @doc """
  Retrieves a Stripe customer by ID.
  """
  @spec get_customer(binary()) :: {:ok, Customer.t()} | {:error, client_error()}
  def get_customer(customer_id) when is_binary(customer_id) do
    get("/customers/#{customer_id}", &Customer.from_map/1)
  end

  # ---------------------------------------------------------------------------
  # Payment Intents
  # ---------------------------------------------------------------------------

  @doc """
  Creates a PaymentIntent for the given amount and currency.
  """
  @spec create_payment_intent(map()) :: {:ok, PaymentIntent.t()} | {:error, client_error()}
  def create_payment_intent(attrs) when is_map(attrs) do
    post("/payment_intents", attrs, &PaymentIntent.from_map/1)
  end

  @doc """
  Confirms a PaymentIntent, triggering the charge attempt.
  """
  @spec confirm_payment_intent(binary(), map()) ::
          {:ok, PaymentIntent.t()} | {:error, client_error()}
  def confirm_payment_intent(intent_id, attrs \\ %{}) when is_binary(intent_id) do
    post("/payment_intents/#{intent_id}/confirm", attrs, &PaymentIntent.from_map/1)
  end

  # ---------------------------------------------------------------------------
  # Private HTTP helpers
  # ---------------------------------------------------------------------------

  defp get(path, decode_fn) do
    url = @base_url <> path

    [url: url, headers: request_headers(), receive_timeout: @request_timeout_ms]
    |> Req.get()
    |> handle_response(decode_fn)
  end

  defp post(path, body, decode_fn) do
    url = @base_url <> path
    form_body = URI.encode_query(flatten_params(body))

    [
      url: url,
      headers: request_headers(),
      body: form_body,
      receive_timeout: @request_timeout_ms
    ]
    |> Req.post()
    |> handle_response(decode_fn)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, decode_fn)
       when status in 200..299 do
    case decode_fn.(body) do
      {:ok, struct} -> {:ok, struct}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _decode_fn) do
    error = parse_stripe_error(body)
    Logger.warning("Stripe API error", status: status, code: error.code, message: error.message)
    {:error, {:http_error, status, error}}
  end

  defp handle_response({:error, exception}, _decode_fn) do
    Logger.error("Stripe network error", reason: inspect(exception))
    {:error, {:network_error, exception}}
  end

  defp parse_stripe_error(%{"error" => err}) do
    %{
      code: Map.get(err, "code", "unknown"),
      message: Map.get(err, "message", "Unknown error"),
      param: Map.get(err, "param"),
      type: Map.get(err, "type", "api_error")
    }
  end

  defp parse_stripe_error(_body) do
    %{code: "unknown", message: "Unexpected response format", param: nil, type: "api_error"}
  end

  defp request_headers do
    api_key = Application.fetch_env!(:my_app, :stripe_secret_key)

    [
      {"authorization", "Bearer #{api_key}"},
      {"stripe-version", @api_version},
      {"content-type", "application/x-www-form-urlencoded"}
    ]
  end

  defp flatten_params(map, prefix \\ nil) do
    Enum.flat_map(map, fn {k, v} ->
      key = if prefix, do: "#{prefix}[#{k}]", else: to_string(k)

      if is_map(v) do
        flatten_params(v, key)
      else
        [{key, to_string(v)}]
      end
    end)
  end
end
```
