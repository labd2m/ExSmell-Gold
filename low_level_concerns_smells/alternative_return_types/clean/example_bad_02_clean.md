```elixir
defmodule MyApp.Billing.Invoice do
  @moduledoc """
  Generates invoices for completed orders. Supports rendering to multiple
  output formats for downstream processing (email attachments, storage, display).
  """

  alias MyApp.Billing.LineItem
  alias MyApp.Billing.TaxCalculator
  alias MyApp.Billing.PdfRenderer
  alias MyApp.Repo
  alias MyApp.Orders.Order

  defstruct [
    :id, :order_id, :customer_id, :issued_at,
    :due_date, :line_items, :subtotal, :tax, :total,
    :currency, :status
  ]

  @default_currency "BRL"
  @payment_terms_days 30

  def generate(order_id, opts \\ []) do
    output = Keyword.get(opts, :output, :struct)
    currency = Keyword.get(opts, :currency, @default_currency)
    include_tax_breakdown = Keyword.get(opts, :include_tax_breakdown, false)

    with {:ok, order} <- Repo.fetch(Order, order_id),
         {:ok, items} <- LineItem.for_order(order_id),
         {:ok, tax_info} <- TaxCalculator.calculate(items, currency) do
      subtotal = Enum.reduce(items, Decimal.new(0), &Decimal.add(&2, &1.total))
      total = Decimal.add(subtotal, tax_info.amount)

      invoice = %__MODULE__{
        id: generate_invoice_id(),
        order_id: order.id,
        customer_id: order.customer_id,
        issued_at: DateTime.utc_now(),
        due_date: Date.add(Date.utc_today(), @payment_terms_days),
        line_items: items,
        subtotal: subtotal,
        tax: tax_info,
        total: total,
        currency: currency,
        status: :draft
      }

      case output do
        :struct ->
          invoice

        :pdf ->
          extra = if include_tax_breakdown, do: [tax_breakdown: tax_info.breakdown], else: []
          PdfRenderer.render(invoice, extra)

        :text ->
          lines = [
            "Invoice #{invoice.id}",
            "Order: #{order.id}",
            "Customer: #{invoice.customer_id}",
            "Issued: #{invoice.issued_at}",
            "Due: #{invoice.due_date}",
            "---",
            Enum.map(items, &"  #{&1.description}: #{&1.total} #{currency}"),
            "---",
            "Subtotal: #{subtotal} #{currency}",
            "Tax: #{tax_info.amount} #{currency}",
            "Total: #{total} #{currency}"
          ]

          if include_tax_breakdown do
            lines ++ ["Tax Breakdown:"] ++ Enum.map(tax_info.breakdown, &"  #{&1.label}: #{&1.amount}")
          else
            lines
          end
      end
    end
  end

  def finalize(%__MODULE__{} = invoice) do
    %{invoice | status: :final}
  end

  def void(%__MODULE__{} = invoice, reason) do
    %{invoice | status: {:void, reason}}
  end

  defp generate_invoice_id do
    "INV-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
