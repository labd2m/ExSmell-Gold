```elixir
defmodule Payments.Processor do
  @moduledoc """
  Handles end-to-end payment processing including fee calculation,
  settlement scheduling, payment detail validation, and transaction
  reference generation for multiple payment method types.
  """

  alias Payments.{Transaction, Gateway, Ledger, FraudEngine, NotificationService}

  @min_payment_amount 0.01

  def process_payment(amount, method, payer, details) do
    with :ok              <- validate_minimum_amount(amount),
         :ok              <- validate_payment_details(%{method: method, details: details}),
         {:ok, fee}       <- compute_fee(amount, method),
         {:ok, txn}       <- build_transaction(amount, fee, method, payer, details),
         :ok              <- FraudEngine.screen(txn),
         {:ok, txn}       <- Gateway.charge(txn),
         {:ok, _}         <- Ledger.record(txn) do
      NotificationService.payment_confirmed(payer, txn)
      {:ok, txn}
    end
  end

  defp compute_fee(amount, method) do
    fee = calculate_processing_fee(amount, method)
    {:ok, fee}
  end

  defp build_transaction(amount, fee, method, payer, details) do
    ref = format_transaction_ref(method)
    settlement_days = get_settlement_period(method)

    txn = %Transaction{
      reference:       ref,
      amount:          amount,
      fee:             fee,
      net_amount:      amount - fee,
      method:          method,
      payer_id:        payer.id,
      details:         details,
      settles_at:      Date.add(Date.utc_today(), settlement_days),
      status:          :pending
    }

    {:ok, txn}
  end

  defp validate_minimum_amount(amount) when amount >= @min_payment_amount, do: :ok
  defp validate_minimum_amount(_), do: {:error, :amount_too_small}

  def calculate_processing_fee(amount, :credit_card) do
    Float.round(amount * 0.029 + 0.30, 2)
  end

  def calculate_processing_fee(amount, :bank_transfer) do
    min(Float.round(amount * 0.008, 2), 5.00)
  end

  def calculate_processing_fee(amount, :digital_wallet) do
    Float.round(amount * 0.015, 2)
  end

  def calculate_processing_fee(amount, _method) do
    Float.round(amount * 0.035, 2)
  end

  def get_settlement_period(:credit_card),    do: 2
  def get_settlement_period(:bank_transfer),  do: 3
  def get_settlement_period(:digital_wallet), do: 1
  def get_settlement_period(_),               do: 5

  def validate_payment_details(%{method: :credit_card, details: d}) do
    required = [:card_number, :expiry, :cvv, :cardholder_name]
    missing  = Enum.reject(required, &Map.has_key?(d, &1))
    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  def validate_payment_details(%{method: :bank_transfer, details: d}) do
    required = [:account_number, :routing_number, :account_holder]
    missing  = Enum.reject(required, &Map.has_key?(d, &1))
    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  def validate_payment_details(%{method: :digital_wallet, details: d}) do
    if Map.has_key?(d, :wallet_token), do: :ok, else: {:error, {:missing_fields, [:wallet_token]}}
  end

  def validate_payment_details(_), do: {:error, :unsupported_payment_method}

  defp format_transaction_ref(:credit_card)    do
    "CC-#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
  end

  defp format_transaction_ref(:bank_transfer) do
    "BT-#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
  end

  defp format_transaction_ref(:digital_wallet) do
    "DW-#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
  end

  defp format_transaction_ref(_method) do
    "TX-#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
  end

  def refund_transaction(%Transaction{status: :settled} = txn, reason) do
    case Gateway.refund(txn.reference, txn.amount) do
      {:ok, _} ->
        Ledger.record_refund(txn, reason)
        NotificationService.refund_confirmed(txn.payer_id, txn)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refund_transaction(%Transaction{status: status}, _reason) do
    {:error, {:cannot_refund, status}}
  end
end
```
