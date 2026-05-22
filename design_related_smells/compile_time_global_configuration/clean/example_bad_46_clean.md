```elixir
defmodule Billing.PaymentProcessor do
  @moduledoc """
  Handles charge creation, retries, and result normalization
  for the platform's billing subsystem.

  Integrates with the configured payment gateway adapter and
  applies platform-level policies such as retry limits and
  default currency selection.
  """

  require Logger

  @max_retry_attempts Application.fetch_env!(:billing, :max_retry_attempts)
  @default_currency   Application.fetch_env!(:billing, :default_currency)
  @charge_timeout_ms  Application.fetch_env!(:billing, :charge_timeout_ms)

  @gateway_adapter Application.compile_env(:billing, :gateway_adapter, Billing.Adapters.Stripe)

  @type money :: %{amount: pos_integer(), currency: String.t()}
  @type charge_result :: {:ok, map()} | {:error, atom(), String.t()}

  @spec charge(map(), money()) :: charge_result()
  def charge(%{id: customer_id} = customer, %{amount: amount} = money) do
    currency = Map.get(money, :currency, @default_currency)

    Logger.info("Initiating charge",
      customer_id: customer_id,
      amount: amount,
      currency: currency
    )

    with {:ok, payment_method} <- fetch_default_payment_method(customer),
         {:ok, request}        <- build_charge_request(payment_method, amount, currency),
         {:ok, response}       <- dispatch_with_timeout(request) do
      Logger.info("Charge succeeded", customer_id: customer_id, charge_id: response["id"])
      {:ok, normalize_response(response)}
    else
      {:error, reason} ->
        Logger.error("Charge failed", customer_id: customer_id, reason: reason)
        {:error, :charge_failed, "Payment could not be completed: #{reason}"}
    end
  end

  @spec retry_failed_charge(map(), money()) :: charge_result()
  def retry_failed_charge(customer, money) do
    do_retry(customer, money, 0)
  end

  defp do_retry(_customer, _money, attempt) when attempt >= @max_retry_attempts do
    Logger.warn("Retry limit reached", max_attempts: @max_retry_attempts)
    {:error, :retry_limit_exceeded, "Exceeded maximum retry attempts (#{@max_retry_attempts})"}
  end

  defp do_retry(customer, money, attempt) do
    backoff_ms = :math.pow(2, attempt) |> round() |> Kernel.*(500)

    Logger.info("Retrying charge", attempt: attempt + 1, backoff_ms: backoff_ms)
    Process.sleep(backoff_ms)

    case charge(customer, money) do
      {:ok, _result} = success ->
        success

      {:error, :charge_failed, _msg} ->
        do_retry(customer, money, attempt + 1)

      {:error, _code, _msg} = terminal ->
        terminal
    end
  end

  defp fetch_default_payment_method(%{payment_methods: [first | _]}), do: {:ok, first}
  defp fetch_default_payment_method(_), do: {:error, "No payment method on file"}

  defp build_charge_request(payment_method, amount, currency) do
    if amount <= 0 do
      {:error, "Charge amount must be positive"}
    else
      request = %{
        payment_method_id: payment_method.id,
        amount:            amount,
        currency:          String.upcase(currency),
        capture:           true,
        metadata:          %{platform: "billing_v2", currency_default: @default_currency}
      }

      {:ok, request}
    end
  end

  defp dispatch_with_timeout(request) do
    task = Task.async(fn -> @gateway_adapter.create_charge(request) end)

    case Task.yield(task, @charge_timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        Logger.error("Gateway timeout", timeout_ms: @charge_timeout_ms)
        {:error, "Gateway did not respond within #{@charge_timeout_ms}ms"}
    end
  end

  defp normalize_response(raw) do
    %{
      charge_id:  raw["id"],
      status:     raw["status"],
      amount:     raw["amount"],
      currency:   raw["currency"],
      created_at: DateTime.utc_now()
    }
  end
end
```
