```elixir
defmodule InvoiceProcessor do
  @moduledoc """
  Handles calculation of invoice totals, tax, and discount application
  for the billing subsystem.
  """

  @tax_rate 0.12
  @max_discount 0.50

  def calculate_total(line_items, discount_rate \\ 0.0) do
    if is_nil(line_items) or line_items == [] do
      raise RuntimeError, message: "Invoice must have at least one line item"
    end

    if discount_rate < 0.0 or discount_rate > @max_discount do
      raise RuntimeError,
        message:
          "Discount rate #{discount_rate} is out of the allowed range [0.0, #{@max_discount}]"
    end

    subtotal =
      Enum.reduce(line_items, Decimal.new("0.00"), fn item, acc ->
        unless Map.has_key?(item, :unit_price) and Map.has_key?(item, :quantity) do
          raise RuntimeError,
            message: "Line item is missing required fields :unit_price or :quantity"
        end

        unless item.quantity > 0 do
          raise RuntimeError,
            message: "Line item quantity must be positive, got: #{item.quantity}"
        end

        line_total =
          Decimal.mult(
            Decimal.new("#{item.unit_price}"),
            Decimal.new("#{item.quantity}")
          )

        Decimal.add(acc, line_total)
      end)

    discount_amount = Decimal.mult(subtotal, Decimal.new("#{discount_rate}"))
    discounted = Decimal.sub(subtotal, discount_amount)
    tax = Decimal.mult(discounted, Decimal.new("#{@tax_rate}"))
    total = Decimal.add(discounted, tax)

    %{
      subtotal: subtotal,
      discount_amount: discount_amount,
      tax: tax,
      total: total
    }
  end

  def format_line_items(line_items) do
    Enum.map(line_items, fn item ->
      %{
        description: Map.get(item, :description, "N/A"),
        quantity: item.quantity,
        unit_price: item.unit_price,
        line_total: item.unit_price * item.quantity
      }
    end)
  end
end

defmodule BillingService do
  @moduledoc """
  Orchestrates invoice generation, persistence, and delivery for customers.
  """

  require Logger

  alias InvoiceProcessor

  def generate_invoice(customer_id, order) do
    line_items = Map.get(order, :line_items, [])
    discount_rate = Map.get(order, :discount_rate, 0.0)

    # Forced to use try/rescue because InvoiceProcessor.calculate_total/1
    # only communicates errors through raised exceptions.
    try do
      totals = InvoiceProcessor.calculate_total(line_items, discount_rate)

      invoice = %{
        id: generate_invoice_id(),
        customer_id: customer_id,
        issued_at: DateTime.utc_now(),
        line_items: InvoiceProcessor.format_line_items(line_items),
        subtotal: totals.subtotal,
        discount_amount: totals.discount_amount,
        tax: totals.tax,
        total: totals.total,
        status: :pending
      }

      Logger.info("Invoice #{invoice.id} generated for customer #{customer_id}")
      {:ok, invoice}
    rescue
      e in RuntimeError ->
        Logger.warning("Invoice generation failed for customer #{customer_id}: #{e.message}")
        {:error, e.message}
    end
  end

  def send_invoice(invoice, delivery_channel) do
    case delivery_channel do
      :email -> Logger.info("Sending invoice #{invoice.id} via email")
      :pdf -> Logger.info("Rendering invoice #{invoice.id} as PDF")
      _ -> Logger.warning("Unknown delivery channel: #{delivery_channel}")
    end

    {:ok, :sent}
  end

  defp generate_invoice_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
