```elixir
defmodule Tax.RateEngine do
  @moduledoc """
  Calculates applicable tax rates for transactions based on the destination
  region and product category, supporting multi-jurisdiction compliance.
  """


  @spec vat_rate(atom(), atom()) :: float()
  def vat_rate(:domestic, :standard),    do: 0.20
  def vat_rate(:domestic, :reduced),     do: 0.05
  def vat_rate(:domestic, :zero_rated),  do: 0.00

  def vat_rate(:eu, :standard),    do: 0.21
  def vat_rate(:eu, :reduced),     do: 0.06
  def vat_rate(:eu, :zero_rated),  do: 0.00

  def vat_rate(:uk, :standard),    do: 0.20
  def vat_rate(:uk, :reduced),     do: 0.05
  def vat_rate(:uk, :zero_rated),  do: 0.00

  def vat_rate(_, _), do: 0.00

  @spec tax_label(atom()) :: String.t()
  def tax_label(:domestic), do: "VAT"
  def tax_label(:eu),       do: "VAT"
  def tax_label(:uk),       do: "VAT"

  @spec tax_inclusive?(atom()) :: boolean()
  def tax_inclusive?(:domestic), do: true
  def tax_inclusive?(:eu),       do: true
  def tax_inclusive?(:uk),       do: true


  def calculate(line_items, region, category) do
    rate = vat_rate(region, category)

    Enum.map(line_items, fn item ->
      tax_amount =
        if tax_inclusive?(region) do
          item.unit_price * item.quantity * rate / (1 + rate)
        else
          item.unit_price * item.quantity * rate
        end

      Map.put(item, :tax_amount, Float.round(tax_amount, 2))
    end)
  end
end

defmodule Tax.ComplianceReporter do
  @moduledoc """
  Generates tax compliance reports and VAT returns for each supported
  fiscal region, formatted according to local regulatory requirements.
  """


  @spec report_currency(atom()) :: String.t()
  def report_currency(:domestic), do: "GBP"
  def report_currency(:eu),       do: "EUR"
  def report_currency(:uk),       do: "GBP"

  @spec filing_frequency(atom()) :: atom()
  def filing_frequency(:domestic), do: :quarterly
  def filing_frequency(:eu),       do: :monthly
  def filing_frequency(:uk),       do: :quarterly


  def build_vat_return(transactions, region, period) do
    label    = Tax.RateEngine.tax_label(region)
    currency = report_currency(region)

    taxable  = Enum.filter(transactions, & &1.region == region)
    output   = taxable |> Enum.map(& &1.tax_amount) |> Enum.sum()
    input    = taxable |> Enum.map(& Map.get(&1, :reclaimable_tax, 0.0)) |> Enum.sum()

    %{
      region:     region,
      period:     period,
      label:      label,
      currency:   currency,
      output_tax: Float.round(output, 2),
      input_tax:  Float.round(input, 2),
      net_due:    Float.round(output - input, 2),
      frequency:  filing_frequency(region)
    }
  end
end

defmodule Tax.InvoiceFormatter do
  @moduledoc """
  Applies region-specific tax line formatting and legal disclosure text
  to customer invoices before PDF generation.
  """


  @spec invoice_tax_line(atom(), float()) :: String.t()
  def invoice_tax_line(:domestic, amount) do
    "VAT @ 20%: #{format_amount(amount, "£")}"
  end

  def invoice_tax_line(:eu, amount) do
    "BTW/MwSt @ 21%: #{format_amount(amount, "€")}"
  end

  def invoice_tax_line(:uk, amount) do
    "VAT @ 20%: #{format_amount(amount, "£")}"
  end

  @spec legal_notice(atom()) :: String.t()
  def legal_notice(:domestic), do: "VAT Registration No: GB123456789"
  def legal_notice(:eu),       do: "BTW-ID: NL123456789B01"
  def legal_notice(:uk),       do: "VAT Registration No: GB987654321"


  def annotate_invoice(invoice) do
    region     = invoice.customer.tax_region
    tax_total  = invoice.line_items |> Enum.map(& &1.tax_amount) |> Enum.sum()

    Map.merge(invoice, %{
      tax_line:     invoice_tax_line(region, tax_total),
      legal_notice: legal_notice(region),
      tax_label:    Tax.RateEngine.tax_label(region)
    })
  end

  defp format_amount(amount, symbol) do
    "#{symbol}#{:erlang.float_to_binary(amount, decimals: 2)}"
  end
end
```
