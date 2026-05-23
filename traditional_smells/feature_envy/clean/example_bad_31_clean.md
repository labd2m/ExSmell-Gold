```elixir
defmodule Tax.InvoiceTaxLine do
  @moduledoc "Represents a single tax line on an invoice, used for VAT computation."

  defstruct [
    :id,
    :invoice_id,
    :description,
    :gross_amount,
    :discount_amount,
    :tax_category,
    :jurisdiction,
    :customer_type,
    :reverse_charge,
    :tax_exempt
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      invoice_id: "INV-9900",
      description: "SaaS Platform License",
      gross_amount: Decimal.new("1000.00"),
      discount_amount: Decimal.new("50.00"),
      tax_category: :digital_services,
      jurisdiction: "DE",
      customer_type: :b2b,
      reverse_charge: false,
      tax_exempt: false
    }
  end

  def net_amount(%__MODULE__{gross_amount: gross, discount_amount: disc}) do
    Decimal.sub(gross, disc)
  end

  def applicable_rate(%__MODULE__{tax_category: :digital_services, jurisdiction: "DE"}), do: Decimal.new("0.19")
  def applicable_rate(%__MODULE__{tax_category: :digital_services, jurisdiction: "FR"}), do: Decimal.new("0.20")
  def applicable_rate(%__MODULE__{tax_category: :digital_services, jurisdiction: "GB"}), do: Decimal.new("0.20")
  def applicable_rate(%__MODULE__{tax_category: :goods, jurisdiction: "DE"}),            do: Decimal.new("0.19")
  def applicable_rate(%__MODULE__{tax_category: :goods, jurisdiction: "FR"}),            do: Decimal.new("0.20")
  def applicable_rate(_), do: Decimal.new("0.21")

  def is_exempt?(%__MODULE__{tax_exempt: true}), do: true
  def is_exempt?(_), do: false

  def reverse_charge?(%__MODULE__{reverse_charge: true, customer_type: :b2b}), do: true
  def reverse_charge?(_), do: false

  def jurisdiction_code(%__MODULE__{jurisdiction: j}), do: j

  def line_reference(%__MODULE__{invoice_id: inv, id: id}), do: "#{inv}/#{id}"
end

defmodule Tax.VatEngine do
  @moduledoc """
  Computes VAT breakdowns for invoice tax lines, taking into account
  jurisdiction-specific rates, exemptions, and reverse-charge rules.
  """

  alias Tax.InvoiceTaxLine
  require Logger

  @doc """
  Processes a list of tax line IDs and returns a structured VAT report.
  """
  def process_invoice_lines(line_ids) do
    breakdowns = Enum.map(line_ids, &compute_vat_breakdown/1)

    total_net = breakdowns |> Enum.map(& &1.net) |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)
    total_vat = breakdowns |> Enum.map(& &1.vat) |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)

    %{
      lines:     breakdowns,
      total_net: Decimal.round(total_net, 2),
      total_vat: Decimal.round(total_vat, 2),
      total_gross: Decimal.round(Decimal.add(total_net, total_vat), 2)
    }
  end

  defp compute_vat_breakdown(line_id) do
    line         = InvoiceTaxLine.get!(line_id)
    net          = InvoiceTaxLine.net_amount(line)
    rate         = InvoiceTaxLine.applicable_rate(line)
    exempt       = InvoiceTaxLine.is_exempt?(line)
    rev_charge   = InvoiceTaxLine.reverse_charge?(line)
    jurisdiction = InvoiceTaxLine.jurisdiction_code(line)

    vat_amount =
      cond do
        exempt     -> Decimal.new("0.00")
        rev_charge -> Decimal.new("0.00")
        true       -> Decimal.round(Decimal.mult(net, rate), 2)
      end

    %{
      line_id:      line_id,
      reference:    InvoiceTaxLine.line_reference(line),
      jurisdiction: jurisdiction,
      net:          net,
      rate:         rate,
      vat:          vat_amount,
      exempt:       exempt,
      reverse_charge: rev_charge,
      gross:        Decimal.add(net, vat_amount)
    }
  end
end
```
