# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Tax.TaxEngine.calculate/3`
- **Affected function(s):** `Tax.TaxEngine.calculate/3` (library side); `Tax.OrderTaxApplicator.apply/2` (client side)
- **Explanation:** `calculate/3` raises `RuntimeError` for foreseeable, routine tax-calculation failures: unsupported region, negative taxable amount, unrecognised product category, and missing customer VAT number for a B2B transaction. These are ordinary input-validation and configuration conditions. Callers processing a list of orders need to collect per-order tax errors, but can only do so via `try/rescue`, making exception handling the sole available control-flow mechanism.

```elixir
defmodule Tax.Region do
  @moduledoc "Tax jurisdiction configuration."

  @enforce_keys [:code, :name, :standard_rate, :currency]
  defstruct [:code, :name, :standard_rate, :currency, :reduced_rates, :b2b_reverse_charge]
end

defmodule Tax.RegionRegistry do
  @moduledoc "Registry of supported tax jurisdictions."

  alias Tax.Region

  @regions %{
    "US-CA" => %Region{code: "US-CA", name: "California", standard_rate: 0.0725, currency: "USD", b2b_reverse_charge: false},
    "US-NY" => %Region{code: "US-NY", name: "New York", standard_rate: 0.08, currency: "USD", b2b_reverse_charge: false},
    "DE" => %Region{code: "DE", name: "Germany", standard_rate: 0.19, currency: "EUR", reduced_rates: %{food: 0.07}, b2b_reverse_charge: true},
    "GB" => %Region{code: "GB", name: "United Kingdom", standard_rate: 0.20, currency: "GBP", reduced_rates: %{food: 0.0}, b2b_reverse_charge: false},
    "BR-SP" => %Region{code: "BR-SP", name: "São Paulo", standard_rate: 0.12, currency: "BRL", b2b_reverse_charge: false}
  }

  def find(code), do: Map.fetch(@regions, code)
  def supported?(code), do: Map.has_key?(@regions, code)
  def all_codes, do: Map.keys(@regions)
end

defmodule Tax.CategoryPolicy do
  @moduledoc "Determines the applicable tax rate for a product category."

  @recognised_categories ~w[physical_goods digital_goods services food software]

  def recognised?(cat), do: cat in @recognised_categories

  def effective_rate(region, category) do
    reduced = region.reduced_rates || %{}
    atom_cat = String.to_existing_atom(category)

    Map.get(reduced, atom_cat, region.standard_rate)
  rescue
    ArgumentError -> region.standard_rate
  end
end

defmodule Tax.TaxBreakdown do
  @moduledoc "Structured result of a tax calculation."

  @enforce_keys [:taxable_amount, :tax_rate, :tax_amount, :total, :region_code, :currency]
  defstruct [
    :taxable_amount,
    :tax_rate,
    :tax_amount,
    :total,
    :region_code,
    :currency,
    :category,
    :reverse_charged
  ]
end

defmodule Tax.TaxEngine do
  @moduledoc """
  Calculates applicable tax for a transaction given a region, amount, and product category.
  Handles B2B reverse charge scenarios for qualifying EU jurisdictions.
  """

  alias Tax.{CategoryPolicy, RegionRegistry, TaxBreakdown}
  require Logger

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `calculate/3` raises RuntimeError for four
  # VALIDATION: expected, non-exceptional tax-calculation failures: unsupported
  # VALIDATION: region, negative taxable amount, unrecognised product category, and
  # VALIDATION: B2B transaction with missing VAT number. These are mundane input
  # VALIDATION: validation and configuration gaps that arise regularly in a multi-
  # VALIDATION: region commerce platform. Callers processing a batch of orders have
  # VALIDATION: no structured {:error, reason} to pattern-match on — they must wrap
  # VALIDATION: every call in try/rescue to accumulate per-order tax errors.
  def calculate(region_code, taxable_amount, opts \\ []) when is_binary(region_code) do
    unless is_number(taxable_amount) and taxable_amount >= 0 do
      raise RuntimeError,
        message:
          "Taxable amount must be a non-negative number, got: #{inspect(taxable_amount)}"
    end

    case RegionRegistry.find(region_code) do
      :error ->
        raise RuntimeError,
          message:
            "Tax region '#{region_code}' is not configured. " <>
              "Supported regions: #{Enum.join(RegionRegistry.all_codes(), ", ")}"

      {:ok, region} ->
        category = Keyword.get(opts, :category, "physical_goods")

        unless CategoryPolicy.recognised?(category) do
          raise RuntimeError,
            message:
              "Product category '#{category}' is not recognised for tax purposes. " <>
                "Recognised categories: physical_goods, digital_goods, services, food, software"
        end

        is_b2b = Keyword.get(opts, :b2b, false)
        vat_number = Keyword.get(opts, :vat_number)

        if is_b2b and region.b2b_reverse_charge and is_nil(vat_number) do
          raise RuntimeError,
            message:
              "B2B transactions in '#{region_code}' require a valid customer VAT number " <>
                "for reverse charge purposes. Please provide the :vat_number option."
        end

        reverse_charge = is_b2b and region.b2b_reverse_charge and not is_nil(vat_number)

        tax_rate = if reverse_charge, do: 0.0, else: CategoryPolicy.effective_rate(region, category)
        tax_amount = Float.round(taxable_amount * tax_rate, 2)

        result = %TaxBreakdown{
          taxable_amount: taxable_amount,
          tax_rate: tax_rate,
          tax_amount: tax_amount,
          total: taxable_amount + tax_amount,
          region_code: region_code,
          currency: region.currency,
          category: category,
          reverse_charged: reverse_charge
        }

        Logger.debug(
          "Tax calculated: region=#{region_code} amount=#{taxable_amount} " <>
            "rate=#{tax_rate} tax=#{tax_amount}"
        )

        result
    end
  end
  # VALIDATION: SMELL END
end

defmodule Tax.OrderTaxApplicator do
  @moduledoc """
  Applies tax calculations to a list of orders.
  Collects per-order failures without aborting the entire batch.
  """

  alias Tax.TaxEngine
  require Logger

  def apply(order, opts \\ []) do
    region = opts[:region] || order.region_code
    category = opts[:category] || order.product_category

    # Client forced to use try/rescue because TaxEngine.calculate/3 raises
    # on all failure conditions instead of returning {:error, reason}.
    try do
      breakdown = TaxEngine.calculate(region, order.subtotal, category: category)

      {:ok,
       %{
         order_id: order.id,
         tax: breakdown.tax_amount,
         rate: breakdown.tax_rate,
         total: breakdown.total,
         currency: breakdown.currency
       }}
    rescue
      e in RuntimeError ->
        Logger.warning("Tax calculation failed for order=#{order.id}: #{e.message}")
        {:error, %{order_id: order.id, reason: e.message}}
    end
  end

  def apply_batch(orders, opts \\ []) when is_list(orders) do
    Logger.info("Applying tax to #{length(orders)} orders")

    results = Enum.map(orders, fn order -> apply(order, opts) end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    err_count = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Tax batch done: #{ok_count} succeeded, #{err_count} failed")
    %{results: results, succeeded: ok_count, failed: err_count}
  end
end
```
