```elixir
defmodule MyApp.Payments.Processor do
  alias MyApp.Payments.{FeeCalculator, ReceiptBuilder}
  alias MyApp.Gateways.{StripeGateway, BankTransferGateway, PixGateway}

  require Logger

  def process(%{method: :credit_card} = payment, user) do
    fee = FeeCalculator.calculate(:credit_card, payment.amount)
    total = payment.amount + fee

    case StripeGateway.charge(user.stripe_customer_id, total, payment.currency) do
      {:ok, charge} ->
        receipt = ReceiptBuilder.build(:credit_card, %{charge: charge, payment: payment, fee: fee})
        Logger.info("Credit card payment processed", payment_id: payment.id, total: total)
        {:ok, receipt}

      {:error, reason} ->
        Logger.error("Credit card payment failed", payment_id: payment.id, reason: reason)
        {:error, reason}
    end
  end

  def process(%{method: :bank_transfer} = payment, user) do
    fee = FeeCalculator.calculate(:bank_transfer, payment.amount)
    total = payment.amount + fee

    case BankTransferGateway.initiate(user.bank_account, total, payment.reference) do
      {:ok, transfer} ->
        receipt = ReceiptBuilder.build(:bank_transfer, %{transfer: transfer, payment: payment, fee: fee})
        Logger.info("Bank transfer initiated", payment_id: payment.id, total: total)
        {:ok, receipt}

      {:error, reason} ->
        Logger.error("Bank transfer failed", payment_id: payment.id, reason: reason)
        {:error, reason}
    end
  end

  def process(%{method: :pix} = payment, user) do
    fee = FeeCalculator.calculate(:pix, payment.amount)
    total = payment.amount + fee

    case PixGateway.generate_qrcode(user.tax_id, total, payment.description) do
      {:ok, pix_data} ->
        receipt = ReceiptBuilder.build(:pix, %{pix_data: pix_data, payment: payment, fee: fee})
        Logger.info("PIX payment initiated", payment_id: payment.id, total: total)
        {:ok, receipt}

      {:error, reason} ->
        Logger.error("PIX payment failed", payment_id: payment.id, reason: reason)
        {:error, reason}
    end
  end

  def process(%{method: unknown}, _user) do
    {:error, {:unsupported_payment_method, unknown}}
  end
end

defmodule MyApp.Payments.FeeCalculator do
  @moduledoc """
  Calculates processing fees for each supported payment method.
  Fees are expressed as decimal fractions of the transaction amount,
  with optional fixed components per method.
  """

  @credit_card_rate 0.029
  @credit_card_fixed 0.30
  @bank_transfer_rate 0.008
  @bank_transfer_fixed 0.00
  @pix_rate 0.0099
  @pix_fixed 0.00

  def calculate(:credit_card, amount) do
    Float.round(amount * @credit_card_rate + @credit_card_fixed, 2)
  end

  def calculate(:bank_transfer, amount) do
    Float.round(amount * @bank_transfer_rate + @bank_transfer_fixed, 2)
  end

  def calculate(:pix, amount) do
    Float.round(amount * @pix_rate + @pix_fixed, 2)
  end

  def calculate(unknown_method, _amount) do
    raise ArgumentError, "No fee rule defined for payment method: #{inspect(unknown_method)}"
  end
end

defmodule MyApp.Payments.ReceiptBuilder do
  @moduledoc """
  Builds structured receipt maps for each payment method.
  Receipts are stored and optionally emailed to the customer after payment.
  """

  def build(:credit_card, %{charge: charge, payment: payment, fee: fee}) do
    %{
      receipt_type: :credit_card,
      payment_id: payment.id,
      amount: payment.amount,
      fee: fee,
      total: payment.amount + fee,
      currency: payment.currency,
      gateway_reference: charge.id,
      last_four: charge.payment_method_details.card.last4,
      card_brand: charge.payment_method_details.card.brand,
      issued_at: DateTime.utc_now()
    }
  end

  def build(:bank_transfer, %{transfer: transfer, payment: payment, fee: fee}) do
    %{
      receipt_type: :bank_transfer,
      payment_id: payment.id,
      amount: payment.amount,
      fee: fee,
      total: payment.amount + fee,
      bank_reference: transfer.reference_id,
      expected_clearance: transfer.estimated_clearance_date,
      issued_at: DateTime.utc_now()
    }
  end

  def build(:pix, %{pix_data: pix_data, payment: payment, fee: fee}) do
    %{
      receipt_type: :pix,
      payment_id: payment.id,
      amount: payment.amount,
      fee: fee,
      total: payment.amount + fee,
      e2e_id: pix_data.end_to_end_id,
      qrcode: pix_data.qrcode_payload,
      expires_at: pix_data.expiration,
      issued_at: DateTime.utc_now()
    }
  end

  def build(unknown_method, _data) do
    {:error, {:no_receipt_template, unknown_method}}
  end
end
```
