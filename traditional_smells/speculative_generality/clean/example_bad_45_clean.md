```elixir
defmodule Billing.FeeCalculator do
  @moduledoc """
  Computes all applicable fees and taxes for customer-facing billing transactions.
  Supports standard, B2B, and tax-exempt customer profiles.
  """

  alias Billing.{Transaction, Customer, TaxProfile}

  @platform_fee_rate         0.015
  @minimum_fee               0.50
  @vat_rate                  0.20
  @b2b_tax_exempt_threshold  1_000.00
  @refund_flat_fee            0.30
  @refund_rate               0.005

  def compute_total_charge(%Transaction{} = txn, %Customer{} = customer) do
    with {:ok, processing_fee} <- calculate_processing_fee(txn),
         {:ok, platform_fee}   <- calculate_platform_fee(txn),
         {:ok, tax_amount}     <- calculate_tax(txn, customer) do
      subtotal = txn.amount + processing_fee + platform_fee
      total    = subtotal + tax_amount

      {:ok,
       %{
         original_amount: txn.amount,
         processing_fee:  processing_fee,
         platform_fee:    platform_fee,
         tax_amount:      tax_amount,
         total_charge:    Float.round(total, 2)
       }}
    end
  end

  def compute_refund_fee(%Transaction{amount: amount}) do
    fee = max(amount * @refund_rate + @refund_flat_fee, 0.50)
    {:ok, Float.round(fee, 2)}
  end

  def calculate_platform_fee(%Transaction{amount: amount}) do
    fee = max(amount * @platform_fee_rate, @minimum_fee)
    {:ok, Float.round(fee, 2)}
  end

  def calculate_tax(
        %Transaction{amount: amount},
        %Customer{tax_profile: %TaxProfile{} = profile}
      ) do
    cond do
      profile.tax_exempt? ->
        {:ok, 0.0}

      profile.b2b? and amount >= @b2b_tax_exempt_threshold ->
        {:ok, 0.0}

      true ->
        {:ok, Float.round(amount * @vat_rate, 2)}
    end
  end

  def calculate_tax(%Transaction{amount: amount}, _customer) do
    {:ok, Float.round(amount * @vat_rate, 2)}
  end

  
  
  
  
  
  
  
  
  def calculate_processing_fee(%{payment_method: method} = transaction) do
    rate =
      case method do
        _ -> 0.029
      end

    fee = max(transaction.amount * rate, @minimum_fee)
    {:ok, Float.round(fee, 2)}
  end
  

  def summarise_charges(%{} = breakdown) do
    total_fees =
      breakdown.processing_fee +
        breakdown.platform_fee +
        breakdown.tax_amount

    effective_rate =
      if breakdown.original_amount > 0 do
        Float.round(total_fees / breakdown.original_amount * 100, 2)
      else
        0.0
      end

    %{
      subtotal:       breakdown.original_amount,
      total_fees:     Float.round(total_fees, 2),
      grand_total:    breakdown.total_charge,
      effective_rate: effective_rate
    }
  end

  def taxable?(%Transaction{amount: amount, currency: currency}) do
    amount > 0 and currency in ["EUR", "GBP", "AUD", "CAD"]
  end

  def format_amount(amount, currency \\ "USD") do
    :erlang.float_to_binary(amount / 1, decimals: 2) <> " " <> currency
  end

  def billable?(%Transaction{amount: amount, status: status}) do
    status in [:pending, :authorized] and amount > 0
  end
end
```
