```elixir
defmodule Billing.InvoiceItem do
  @moduledoc "Represents a single line item on an invoice."

  defstruct [
    :id,
    :invoice_id,
    :description,
    :unit_price,
    :quantity,
    :category,
    :tax_code,
    :discount_code,
    :surcharge_type
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      invoice_id: "INV-001",
      description: "Professional Services – Q1",
      unit_price: Decimal.new("150.00"),
      quantity: 8,
      category: :services,
      tax_code: "TX_STD",
      discount_code: "DISC_10",
      surcharge_type: :none
    }
  end

  def get_tax_rate(%__MODULE__{tax_code: "TX_STD"}), do: Decimal.new("0.15")
  def get_tax_rate(%__MODULE__{tax_code: "TX_REDUCED"}), do: Decimal.new("0.07")
  def get_tax_rate(%__MODULE__{tax_code: "TX_ZERO"}), do: Decimal.new("0.00")
  def get_tax_rate(_), do: Decimal.new("0.15")

  def get_discount(%__MODULE__{discount_code: "DISC_10"}), do: Decimal.new("0.10")
  def get_discount(%__MODULE__{discount_code: "DISC_20"}), do: Decimal.new("0.20")
  def get_discount(_), do: Decimal.new("0.00")

  def get_surcharge(%__MODULE__{surcharge_type: :express}), do: Decimal.new("25.00")
  def get_surcharge(%__MODULE__{surcharge_type: :hazmat}), do: Decimal.new("50.00")
  def get_surcharge(_), do: Decimal.new("0.00")

  def formatted_label(%__MODULE__{description: desc, quantity: qty, unit_price: price}) do
    "#{desc} (#{qty} x #{price})"
  end
end

defmodule Billing.Invoice do
  @moduledoc "Represents an invoice header."

  defstruct [
    :id,
    :customer_id,
    :issued_at,
    :due_date,
    :status,
    :line_item_ids,
    :notes,
    :currency
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      customer_id: "CUST-042",
      issued_at: ~D[2024-01-15],
      due_date: ~D[2024-02-15],
      status: :pending,
      line_item_ids: ["LI-001", "LI-002", "LI-003"],
      notes: "Net 30",
      currency: "USD"
    }
  end

  def overdue?(%__MODULE__{due_date: due, status: status}) do
    status != :paid and Date.compare(due, Date.utc_today()) == :lt
  end
end

defmodule Billing.InvoiceSummary do
  @moduledoc """
  Builds human-readable summaries for invoices, including grand totals
  across all line items.
  """

  alias Billing.{Invoice, InvoiceItem}

  @doc """
  Builds a summary map for the given invoice ID, computing the grand total
  from all associated line items.
  """
  def build(invoice_id) do
    invoice = Invoice.get!(invoice_id)

    line_totals =
      invoice.line_item_ids
      |> Enum.map(&calculate_line_total/1)

    grand_total =
      Enum.reduce(line_totals, Decimal.new("0.00"), &Decimal.add/2)

    %{
      invoice_id: invoice.id,
      customer_id: invoice.customer_id,
      issued_at: invoice.issued_at,
      due_date: invoice.due_date,
      status: if(Invoice.overdue?(invoice), do: :overdue, else: invoice.status),
      currency: invoice.currency,
      grand_total: Decimal.round(grand_total, 2),
      notes: invoice.notes
    }
  end

  defp calculate_line_total(line_id) do
    line     = InvoiceItem.get!(line_id)
    base     = Decimal.mult(line.unit_price, Decimal.new(line.quantity))
    tax_rate = InvoiceItem.get_tax_rate(line)
    discount = InvoiceItem.get_discount(line)
    surcharge = InvoiceItem.get_surcharge(line)

    taxed      = Decimal.mult(base, Decimal.add(Decimal.new("1"), tax_rate))
    discounted = Decimal.sub(taxed, Decimal.mult(taxed, discount))
    Decimal.add(discounted, surcharge)
  end

  defp format_currency(amount, currency) do
    "#{currency} #{Decimal.round(amount, 2)}"
  end
end
```
