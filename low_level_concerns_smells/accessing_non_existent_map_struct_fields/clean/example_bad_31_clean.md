```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice computation for B2B billing cycles.
  Supports standard, discounted, and tax-exempt invoices.
  """

  require Logger

  @default_tax_rate 0.15
  @late_fee_rate    0.02

  @type line_item :: %{
          description: String.t(),
          quantity: pos_integer(),
          unit_price: float()
        }

  @type invoice :: %{
          id: String.t(),
          customer_id: String.t(),
          issued_at: DateTime.t(),
          due_date: Date.t(),
          line_items: [line_item()],
          currency: String.t(),
          optional(:discount_rate) => float(),
          optional(:tax_exempt) => boolean(),
          optional(:early_payment_discount) => float()
        }

  @spec compute_totals(invoice()) :: {:ok, map()} | {:error, String.t()}
  def compute_totals(invoice) do
    with {:ok, subtotal} <- sum_line_items(invoice.line_items),
         {:ok, result}   <- apply_financials(invoice, subtotal) do
      {:ok, result}
    else
      {:error, reason} ->
        Logger.error("Failed to compute invoice #{invoice.id}: #{reason}")
        {:error, reason}
    end
  end

  defp sum_line_items([]), do: {:error, "invoice has no line items"}
  defp sum_line_items(items) do
    total =
      Enum.reduce(items, 0.0, fn item, acc ->
        acc + item.quantity * item.unit_price
      end)

    {:ok, Float.round(total, 2)}
  end

  defp apply_financials(invoice, subtotal) do
    discount_rate         = invoice[:discount_rate]
    tax_exempt            = invoice[:tax_exempt]
    early_payment_discount = invoice[:early_payment_discount]

    discount_amount =
      if discount_rate do
        Float.round(subtotal * discount_rate, 2)
      else
        0.0
      end

    after_discount = subtotal - discount_amount

    early_discount_amount =
      if early_payment_discount do
        Float.round(after_discount * early_payment_discount, 2)
      else
        0.0
      end

    after_early = after_discount - early_discount_amount

    tax_amount =
      if tax_exempt do
        0.0
      else
        Float.round(after_early * @default_tax_rate, 2)
      end

    total = Float.round(after_early + tax_amount, 2)

    {:ok,
     %{
       invoice_id:             invoice.id,
       customer_id:            invoice.customer_id,
       currency:               invoice.currency,
       subtotal:               subtotal,
       discount_amount:        discount_amount,
       early_payment_discount: early_discount_amount,
       tax_amount:             tax_amount,
       total:                  total,
       due_date:               invoice.due_date
     }}
  end

  @spec apply_late_fee(map(), Date.t()) :: map()
  def apply_late_fee(totals, today) do
    if Date.compare(today, totals.due_date) == :gt do
      late_fee = Float.round(totals.total * @late_fee_rate, 2)
      %{totals | total: totals.total + late_fee, late_fee: late_fee}
    else
      Map.put(totals, :late_fee, 0.0)
    end
  end

  @spec format_summary(map()) :: String.t()
  def format_summary(totals) do
    """
    Invoice #{totals.invoice_id} (#{totals.currency})
    -----------------------------------------------
    Subtotal:               #{totals.subtotal}
    Discount:              -#{totals.discount_amount}
    Early-payment Disc.:   -#{totals.early_payment_discount}
    Tax:                   +#{totals.tax_amount}
    Late Fee:              +#{Map.get(totals, :late_fee, 0.0)}
    -----------------------------------------------
    TOTAL:                  #{totals.total}
    """
  end
end
```
