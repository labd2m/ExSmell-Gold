```elixir
defmodule NumberFormatter do
  def format_currency(amount, currency \\ "USD") do
    :erlang.float_to_binary(amount / 1, decimals: 2)
    |> then(&"#{currency} #{&1}")
  end

  def format_percentage(value) do
    :erlang.float_to_binary(value * 100.0, decimals: 2) <> "%"
  end

  def round_half_up(value, decimals \\ 2) do
    factor = :math.pow(10, decimals)
    Float.round(value * factor) / factor
  end
end

defmodule InvoiceHelpers do
  defmacro __using__(_opts) do
    quote do
      import NumberFormatter

      def subtotal(line_items) do
        Enum.reduce(line_items, 0.0, fn %{qty: qty, unit_price: price}, acc ->
          acc + qty * price
        end)
      end

      def apply_discount(amount, discount_pct) when discount_pct >= 0 and discount_pct <= 1 do
        amount - amount * discount_pct
      end

      def apply_tax(amount, tax_rate) do
        amount + amount * tax_rate
      end

      def line_item_total(%{qty: qty, unit_price: price, discount: disc}) do
        (qty * price) * (1 - disc)
      end
    end
  end

  def subtotal(line_items) do
    Enum.reduce(line_items, 0.0, fn %{qty: qty, unit_price: price}, acc ->
      acc + qty * price
    end)
  end
end

defmodule InvoiceProcessor do
  use InvoiceHelpers

  @default_tax_rate 0.08
  @default_currency "USD"

  def process(invoice) do
    line_items = Map.get(invoice, :line_items, [])

    raw_subtotal = subtotal(line_items)
    discounted   = apply_discount(raw_subtotal, invoice[:discount] || 0.0)
    taxed        = apply_tax(discounted, invoice[:tax_rate] || @default_tax_rate)
    total        = round_half_up(taxed)

    %{
      invoice_id:      invoice.id,
      customer_id:     invoice.customer_id,
      line_items:      Enum.map(line_items, &enrich_line_item/1),
      subtotal_raw:    raw_subtotal,
      subtotal_fmt:    format_currency(raw_subtotal, @default_currency),
      discount_pct:    format_percentage(invoice[:discount] || 0.0),
      tax_rate:        format_percentage(invoice[:tax_rate] || @default_tax_rate),
      total:           total,
      total_fmt:       format_currency(total, @default_currency),
      issued_at:       DateTime.utc_now(),
      status:          :pending
    }
  end

  def build_summary(invoices) do
    invoices
    |> Enum.map(&process/1)
    |> Enum.reduce(%{count: 0, total: 0.0}, fn inv, acc ->
      %{acc | count: acc.count + 1, total: acc.total + inv.total}
    end)
    |> then(fn %{count: c, total: t} ->
      %{
        invoice_count:   c,
        grand_total:     round_half_up(t),
        grand_total_fmt: format_currency(round_half_up(t), @default_currency)
      }
    end)
  end

  def validate_line_items(line_items) do
    Enum.all?(line_items, fn item ->
      Map.has_key?(item, :qty) and
      Map.has_key?(item, :unit_price) and
      item.qty > 0 and
      item.unit_price >= 0.0
    end)
  end

  defp enrich_line_item(item) do
    total = line_item_total(Map.put_new(item, :discount, 0.0))
    Map.put(item, :line_total, round_half_up(total))
  end
end
```
