# Annotated Bad Example 01

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@gateway_url` defined at the top of `Billing.PaymentGateway`
- **Affected function(s):** `charge/2`, `refund/2`
- **Short explanation:** `Application.fetch_env!/2` is called in the module body to set the `@gateway_url` attribute. Module attributes are resolved at compile-time, but the Application Environment is not yet loaded at that point, which can cause warnings or runtime errors during compilation.

---

```elixir
defmodule Billing.PaymentGateway do
  @moduledoc """
  Handles communication with the external payment gateway for charging
  and refunding customer transactions. Supports idempotent retries and
  structured error responses.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called in the
  # VALIDATION: module body to assign a value to a module attribute. Module attributes
  # VALIDATION: are evaluated at compile-time, but the Application Environment may not
  # VALIDATION: be loaded yet, causing warnings or ArgumentError during compilation.
  @gateway_url Application.fetch_env!(:billing, :gateway_url)
  # VALIDATION: SMELL END

  @default_currency "USD"
  @request_timeout_ms 5_000
  @max_retries 3

  @type charge_params :: %{
          amount: pos_integer(),
          currency: String.t(),
          customer_id: String.t(),
          description: String.t()
        }

  @type gateway_result ::
          {:ok, %{transaction_id: String.t(), status: String.t()}}
          | {:error, %{code: String.t(), message: String.t()}}

  @doc """
  Charges a customer via the configured payment gateway.

  ## Parameters
    - `customer_id` - The unique identifier for the customer.
    - `params` - A map with `:amount` (in cents), `:currency`, and `:description`.

  ## Examples

      iex> Billing.PaymentGateway.charge("cust_123", %{amount: 5000, description: "Subscription"})
      {:ok, %{transaction_id: "txn_abc", status: "succeeded"}}
  """
  @spec charge(String.t(), charge_params()) :: gateway_result()
  def charge(customer_id, params) when is_binary(customer_id) and is_map(params) do
    amount = Map.get(params, :amount)
    currency = Map.get(params, :currency, @default_currency)
    description = Map.get(params, :description, "")

    payload = %{
      customer: customer_id,
      amount: amount,
      currency: currency,
      description: description
    }

    Logger.info("Initiating charge for customer=#{customer_id} amount=#{amount} currency=#{currency}")

    case do_request(:post, "#{@gateway_url}/charges", payload) do
      {:ok, %{"id" => txn_id, "status" => status}} ->
        Logger.info("Charge succeeded transaction_id=#{txn_id}")
        {:ok, %{transaction_id: txn_id, status: status}}

      {:error, %{"code" => code, "message" => msg}} ->
        Logger.error("Charge failed code=#{code} message=#{msg}")
        {:error, %{code: code, message: msg}}
    end
  end

  @doc """
  Refunds a previously successful transaction, either partially or in full.

  ## Parameters
    - `transaction_id` - The ID returned by a prior `charge/2` call.
    - `amount` - The amount in cents to refund. Defaults to full refund if nil.
  """
  @spec refund(String.t(), pos_integer() | nil) :: gateway_result()
  def refund(transaction_id, amount \\ nil) when is_binary(transaction_id) do
    payload =
      if amount do
        %{transaction_id: transaction_id, amount: amount}
      else
        %{transaction_id: transaction_id}
      end

    Logger.info("Initiating refund for transaction_id=#{transaction_id}")

    case do_request(:post, "#{@gateway_url}/refunds", payload) do
      {:ok, %{"id" => refund_id, "status" => status}} ->
        Logger.info("Refund succeeded refund_id=#{refund_id}")
        {:ok, %{transaction_id: refund_id, status: status}}

      {:error, %{"code" => code, "message" => msg}} ->
        Logger.error("Refund failed code=#{code} message=#{msg}")
        {:error, %{code: code, message: msg}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_request(method, url, payload, retries \\ 0) do
    body = Jason.encode!(payload)

    result =
      case method do
        :post -> HTTPoison.post(url, body, json_headers(), recv_timeout: @request_timeout_ms)
        :get -> HTTPoison.get(url, json_headers(), recv_timeout: @request_timeout_ms)
      end

    case result do
      {:ok, %HTTPoison.Response{status_code: code, body: resp_body}} when code in 200..299 ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %HTTPoison.Response{body: resp_body}} ->
        {:error, Jason.decode!(resp_body)}

      {:error, %HTTPoison.Error{reason: :timeout}} when retries < @max_retries ->
        Logger.warning("Gateway timeout, retrying attempt #{retries + 1}/#{@max_retries}")
        do_request(method, url, payload, retries + 1)

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, %{code: "network_error", message: inspect(reason)}}
    end
  end

  defp json_headers do
    [{"Content-Type", "application/json"}, {"Accept", "application/json"}]
  end
end
```
