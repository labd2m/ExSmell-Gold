```elixir
defmodule TaxCalculator do
  @moduledoc """
  Computes applicable taxes on invoice line items for customers
  across multiple jurisdictions. Handles standard, reduced, zero-rate,
  exempt, and reverse-charge VAT categories per EU tax rules.
  """

  alias TaxCalculator.{LineItem, TaxLine, Customer, JurisdictionConfig}

  @type tax_category :: :standard | :reduced | :zero | :exempt | :reverse_charge

  @spec calculate_invoice_tax(Customer.t(), [LineItem.t()]) :: [TaxLine.t()]
  def calculate_invoice_tax(%Customer{} = customer, line_items) do
    config = JurisdictionConfig.for_country(customer.country_code)

    Enum.map(line_items, fn item ->
      rate = tax_rate(item.tax_category, config)
      tax_amount = Float.round(item.net_amount * rate, 2)

      %TaxLine{
        line_item_id: item.id,
        category: item.tax_category,
        rate: rate,
        amount: tax_amount,
        description: tax_description(item.tax_category)
      }
    end)
  end

  @spec build_tax_breakdown([TaxLine.t()]) :: map()
  def build_tax_breakdown(tax_lines) do
    grouped = Enum.group_by(tax_lines, & &1.category)

    Enum.into(grouped, %{}, fn {category, lines} ->
      total = Enum.sum(Enum.map(lines, & &1.amount))
      {category, %{total: total, description: tax_description(category), count: length(lines)}}
    end)
  end

  @spec applies_vat?(tax_category()) :: boolean()
  def applies_vat?(category), do: category in [:standard, :reduced]

  @spec tax_rate(tax_category(), JurisdictionConfig.t()) :: float()
  def tax_rate(tax_category, %JurisdictionConfig{} = config) do
    case tax_category do
      :standard      -> config.standard_rate
      :reduced       -> config.reduced_rate
      :zero          -> 0.0
      :exempt        -> 0.0
      :reverse_charge -> 0.0
    end
  end

  @spec tax_description(tax_category()) :: String.t()
  def tax_description(tax_category) do
    case tax_category do
      :standard       -> "Standard Rate VAT"
      :reduced        -> "Reduced Rate VAT"
      :zero           -> "Zero Rate VAT"
      :exempt         -> "VAT Exempt"
      :reverse_charge -> "Reverse Charge VAT"
    end
  end

  @spec validate_category(atom()) :: :ok | {:error, String.t()}
  def validate_category(category) do
    valid = [:standard, :reduced, :zero, :exempt, :reverse_charge]

    if category in valid do
      :ok
    else
      {:error, "invalid tax category: #{category}. Valid categories: #{inspect(valid)}"}
    end
  end

  @spec effective_rate_label(tax_category(), JurisdictionConfig.t()) :: String.t()
  def effective_rate_label(category, config) do
    rate = tax_rate(category, config)
    description = tax_description(category)
    pct = Float.round(rate * 100, 1)
    "#{description} (#{pct}%)"
  end
end
```
