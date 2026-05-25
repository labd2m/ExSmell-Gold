```elixir
defmodule BillingProcessor do
  @moduledoc """
  Handles payment processing, fee calculation, and receipt generation
  for the billing subsystem.
  """

  require Logger

  @bank_transfer_min_fee 2.50
  @pix_fee_rate 0.0
  @credit_fee_rate 0.029
  @debit_fee_rate 0.015







  @doc """
  Calculates the processing fee for a given payment based on the payment method.
  """
  def calculate_processing_fee(%{payment_method: payment_method, amount: amount}) do
    case payment_method do
      :credit_card ->
        trunc_fee = Float.round(amount * @credit_fee_rate, 2)
        {:ok, trunc_fee}

      :debit_card ->
        trunc_fee = Float.round(amount * @debit_fee_rate, 2)
        {:ok, trunc_fee}

      :bank_transfer ->
        fee = max(@bank_transfer_min_fee, Float.round(amount * 0.005, 2))
        {:ok, fee}

      :pix ->
        {:ok, @pix_fee_rate}

      other ->
        {:error, {:unsupported_payment_method, other}}
    end
  end

  @doc """
  Builds a human-readable receipt map for the given payment transaction.
  """
  def build_payment_receipt(%{
        payment_method: payment_method,
        amount: amount,
        transaction_id: tx_id,
        payer: payer
      }) do
    method_label =
      case payment_method do
        :credit_card -> "Credit Card"
        :debit_card -> "Debit Card"
        :bank_transfer -> "Bank Transfer"
        :pix -> "PIX Instant Payment"
        other -> "Unknown (#{other})"
      end

    %{
      transaction_id: tx_id,
      payer_name: payer.name,
      payer_document: payer.document,
      payment_method_label: method_label,
      amount: amount,
      issued_at: DateTime.utc_now()
    }
  end

  @doc """
  Logs payment attempt details to the application logger at the appropriate level.
  """
  def log_payment_attempt(%{payment_method: payment_method, amount: amount, status: status}) do
    channel =
      case payment_method do
        :credit_card -> "cc_gateway"
        :debit_card -> "debit_gateway"
        :bank_transfer -> "bank_gateway"
        :pix -> "pix_gateway"
        other -> "unknown_gateway_#{other}"
      end



    case status do
      :success ->
        Logger.info("[#{channel}] Payment of R$#{amount} succeeded.")

      :failure ->
        Logger.warning("[#{channel}] Payment of R$#{amount}} failed.")

      :pending ->
        Logger.debug("[#{channel}] Payment of R$#{amount} is pending.")
    end
  end

  @doc """
  Validates that the payment struct contains all required fields for processing.
  """
  def validate_payment(%{payment_method: _, amount: amount} = payment)
      when is_float(amount) and amount > 0 do
    required_keys = [:transaction_id, :payer, :payment_method, :amount]

    missing =
      Enum.filter(required_keys, fn key -> not Map.has_key?(payment, key) end)

    if Enum.empty?(missing) do
      {:ok, payment}
    else
      {:error, {:missing_fields, missing}}
    end
  end

  def validate_payment(_), do: {:error, :invalid_payment_struct}

  @doc """
  Processes a full payment lifecycle: validate → calculate fee → build receipt → log.
  """
  def process(%{} = payment) do
    with {:ok, valid_payment} <- validate_payment(payment),
         {:ok, fee} <- calculate_processing_fee(valid_payment),
         receipt <- build_payment_receipt(valid_payment) do
      log_payment_attempt(Map.put(valid_payment, :status, :success))

      {:ok,
       %{
         receipt: receipt,
         fee: fee,
         net_amount: payment.amount - fee
       }}
    else
      {:error, reason} ->
        Logger.error("Payment processing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```
