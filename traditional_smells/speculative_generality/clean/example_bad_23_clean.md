```elixir
defmodule Payments.FeeCalculator do
  @moduledoc """
  Calculates processing fees for payment transactions.

  Fees include a percentage-based processing fee and, where applicable,
  a fixed per-transaction gateway surcharge. The final amount charged to
  the merchant is the transaction amount plus all applicable fees.
  """

  alias Payments.{Transaction, FeeSchedule}

  @gateway_surcharge 0.30
  @currency_conversion_markup 0.015

  @spec calculate(Transaction.t()) :: {:ok, FeeSchedule.t()} | {:error, atom()}
  def calculate(%Transaction{} = txn) do
    with :ok <- validate_transaction(txn),
         {:ok, processing_fee} <- compute_processing_fee(txn),
         {:ok, gateway_fee} <- compute_gateway_fee(txn) do
      total_fee = Float.round(processing_fee + gateway_fee, 2)

      schedule = %FeeSchedule{
        transaction_id: txn.id,
        processing_fee: processing_fee,
        gateway_fee: gateway_fee,
        total_fee: total_fee,
        net_amount: Float.round(txn.amount - total_fee, 2),
        currency: txn.currency,
        calculated_at: DateTime.utc_now()
      }

      {:ok, schedule}
    end
  end

  defp compute_processing_fee(%{payment_method: payment_method, amount: amount}) do
    rate =
      case payment_method do
        :credit_card -> 0.029
        :debit_card -> 0.029
        :bank_transfer -> 0.029
      end

    {:ok, Float.round(amount * rate, 2)}
  end

  defp compute_gateway_fee(%Transaction{currency: "USD", amount: amount}) do
    {:ok, Float.round(amount * 0 + @gateway_surcharge, 2)}
  end

  defp compute_gateway_fee(%Transaction{currency: currency, amount: amount})
       when currency != "USD" do
    conversion_fee = Float.round(amount * @currency_conversion_markup, 2)
    {:ok, conversion_fee + @gateway_surcharge}
  end

  defp validate_transaction(%Transaction{amount: amount}) when amount <= 0 do
    {:error, :invalid_amount}
  end

  defp validate_transaction(%Transaction{payment_method: nil}) do
    {:error, :missing_payment_method}
  end

  defp validate_transaction(%Transaction{currency: nil}) do
    {:error, :missing_currency}
  end

  defp validate_transaction(_txn), do: :ok
end

defmodule Payments.ChargeProcessor do
  @moduledoc """
  Orchestrates the full charge lifecycle: fee calculation, gateway submission,
  and ledger recording.
  """

  alias Payments.{FeeCalculator, Transaction, GatewayClient, Ledger}

  require Logger

  @spec process(Transaction.t()) :: {:ok, map()} | {:error, atom()}
  def process(%Transaction{} = txn) do
    with {:ok, fee_schedule} <- FeeCalculator.calculate(txn),
         {:ok, gateway_ref} <- GatewayClient.charge(txn, fee_schedule),
         :ok <- Ledger.record(txn, fee_schedule, gateway_ref) do
      Logger.info("Processed transaction id=#{txn.id} ref=#{gateway_ref}")
      {:ok, %{transaction_id: txn.id, gateway_ref: gateway_ref, fees: fee_schedule}}
    else
      {:error, reason} ->
        Logger.error("Failed to process transaction id=#{txn.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```
