```elixir
defmodule Payments.GatewayAdapter do
  @moduledoc """
  Adapter for the external payment gateway. Handles charging, refunding,
  pre-authorization captures, and currency conversion for the checkout flow.
  """

  require Logger

  alias Payments.Repo
  alias Payments.Schema.{Transaction, Refund, PaymentMethod}
  alias Payments.ExchangeRateClient

  @supported_currencies ~w(USD EUR BRL GBP JPY)
  @max_charge_usd 50_000.0
  @gateway_timeout_ms 10_000


  @spec charge(PaymentMethod.t(), float(), String.t()) ::
          {:ok, Transaction.t()} | {:error, term()}
  def charge(%PaymentMethod{} = payment_method, amount, currency)
      when is_float(amount) and is_binary(currency) do
    with :ok <- validate_currency(currency),
         :ok <- validate_amount(amount, currency),
         {:ok, gateway_ref} <- dispatch_charge(payment_method, amount, currency) do
      attrs = %{
        payment_method_id: payment_method.id,
        amount: amount,
        currency: currency,
        gateway_reference: gateway_ref,
        status: :captured,
        charged_at: DateTime.utc_now()
      }

      case %Transaction{} |> Transaction.changeset(attrs) |> Repo.insert() do
        {:ok, txn} ->
          Logger.info("Charge captured: ref=#{gateway_ref} amount=#{amount} #{currency}")
          {:ok, txn}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @spec refund(Transaction.t(), float()) :: {:ok, Refund.t()} | {:error, term()}
  def refund(%Transaction{} = transaction, refund_amount) when is_float(refund_amount) do
    cond do
      refund_amount <= 0.0 ->
        {:error, :invalid_refund_amount}

      refund_amount > transaction.amount ->
        {:error, {:refund_exceeds_original, transaction.amount, refund_amount}}

      true ->
        with {:ok, gateway_ref} <-
               dispatch_refund(transaction.gateway_reference, refund_amount, transaction.currency) do
          attrs = %{
            transaction_id: transaction.id,
            amount: refund_amount,
            currency: transaction.currency,
            gateway_reference: gateway_ref,
            refunded_at: DateTime.utc_now()
          }

          %Refund{} |> Refund.changeset(attrs) |> Repo.insert()
        end
    end
  end

  @spec capture_preauthorization(Transaction.t(), float()) ::
          {:ok, Transaction.t()} | {:error, term()}
  def capture_preauthorization(%Transaction{status: :authorized} = txn, capture_amount)
      when is_float(capture_amount) do
    if capture_amount > txn.amount do
      {:error, {:exceeds_authorized_amount, txn.amount}}
    else
      with {:ok, _ref} <- dispatch_capture(txn.gateway_reference, capture_amount) do
        txn
        |> Transaction.changeset(%{
          amount: capture_amount,
          status: :captured,
          captured_at: DateTime.utc_now()
        })
        |> Repo.update()
      end
    end
  end

  @spec convert_currency(float(), String.t(), String.t()) ::
          {:ok, float()} | {:error, term()}
  def convert_currency(amount, from_currency, to_currency)
      when is_float(amount) and is_binary(from_currency) and is_binary(to_currency) do
    with :ok <- validate_currency(from_currency),
         :ok <- validate_currency(to_currency),
         {:ok, rate} <- ExchangeRateClient.get_rate(from_currency, to_currency) do
      converted = Float.round(amount * rate, 2)
      Logger.debug("Converted #{amount} #{from_currency} -> #{converted} #{to_currency}")
      {:ok, converted}
    end
  end


  ## Private helpers

  defp validate_currency(currency) when currency in @supported_currencies, do: :ok
  defp validate_currency(currency), do: {:error, {:unsupported_currency, currency}}

  defp validate_amount(amount, "USD") when amount > @max_charge_usd,
    do: {:error, {:amount_exceeds_limit, amount, @max_charge_usd}}

  defp validate_amount(amount, _) when amount <= 0.0,
    do: {:error, {:invalid_amount, amount}}

  defp validate_amount(_amount, _currency), do: :ok

  defp dispatch_charge(payment_method, amount, currency) do
    payload = %{
      source: payment_method.gateway_token,
      amount: trunc(amount * 100),
      currency: String.downcase(currency)
    }

    case HTTPClient.post("/charges", payload, timeout: @gateway_timeout_ms) do
      {:ok, %{"id" => ref}} -> {:ok, ref}
      {:error, reason} -> {:error, {:gateway_error, reason}}
    end
  end

  defp dispatch_refund(gateway_ref, amount, currency) do
    payload = %{charge: gateway_ref, amount: trunc(amount * 100), currency: String.downcase(currency)}

    case HTTPClient.post("/refunds", payload, timeout: @gateway_timeout_ms) do
      {:ok, %{"id" => ref}} -> {:ok, ref}
      {:error, reason} -> {:error, {:gateway_error, reason}}
    end
  end

  defp dispatch_capture(gateway_ref, amount) do
    case HTTPClient.post("/charges/#{gateway_ref}/capture", %{amount: trunc(amount * 100)}) do
      {:ok, _} -> {:ok, gateway_ref}
      {:error, reason} -> {:error, {:gateway_error, reason}}
    end
  end
end
```