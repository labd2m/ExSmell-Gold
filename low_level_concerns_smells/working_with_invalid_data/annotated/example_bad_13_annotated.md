# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `TaxCalculator.compute/3`, where `rate` is used directly in multiplication
- **Affected function(s):** `compute/3`, `apply_regional_rate/3`
- **Short explanation:** The `rate` parameter is multiplied against the `taxable_amount` without any prior check that it is a number. If a caller passes a string such as `"0.08"` or an atom, the `ArithmeticError` surfaces inside the multiplication expression with no indication that the invalid data entered the system at the `compute/3` boundary.

```elixir
defmodule MyApp.Finance.TaxCalculator do
  @moduledoc """
  Computes applicable tax amounts for orders, subscriptions, and one-time charges
  based on jurisdiction rules, product tax codes, and customer exemption status.
  """

  require Logger

  alias MyApp.Finance.{TaxJurisdiction, ExemptionRegistry, TaxAuditLog}
  alias MyApp.Accounts.Customer

  @rounding_precision 2
  @minimum_taxable_amount 0.01
  @supported_tax_types [:sales, :vat, :gst, :hst, :pst]

  @type tax_opts :: [
          tax_type: atom(),
          product_tax_code: String.t(),
          override_rate: number() | nil,
          include_breakdown: boolean()
        ]

  @spec compute(Customer.t(), number(), String.t(), tax_opts()) ::
          {:ok, map()} | {:error, atom()}
  def compute(customer, taxable_amount, jurisdiction_code, opts \\ []) do
    tax_type = Keyword.get(opts, :tax_type, :sales)
    product_code = Keyword.get(opts, :product_tax_code, "GENERAL")
    include_breakdown = Keyword.get(opts, :include_breakdown, false)

    with :ok <- validate_tax_type(tax_type),
         {:ok, jurisdiction} <- TaxJurisdiction.fetch(jurisdiction_code),
         :ok <- check_minimum_amount(taxable_amount),
         false <- ExemptionRegistry.exempt?(customer.id, jurisdiction_code, product_code) do
      rate = Keyword.get(opts, :override_rate) || jurisdiction.rate

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `rate` is used in a multiplication
      # VALIDATION: expression without validating it is a number. An override_rate
      # VALIDATION: coming from external configuration or a caller could be a
      # VALIDATION: binary string or nil, causing an ArithmeticError deep inside
      # VALIDATION: the multiplication, far from the point of entry.
      tax_amount = Float.round(taxable_amount * rate, @rounding_precision)
      # VALIDATION: SMELL END

      result = %{
        taxable_amount: taxable_amount,
        rate: rate,
        tax_amount: tax_amount,
        tax_type: tax_type,
        jurisdiction_code: jurisdiction_code,
        total: Float.round(taxable_amount + tax_amount, @rounding_precision)
      }

      result =
        if include_breakdown do
          Map.put(result, :breakdown, build_breakdown(taxable_amount, jurisdiction))
        else
          result
        end

      TaxAuditLog.record(customer.id, result)
      Logger.debug("Tax computed: customer=#{customer.id} jurisdiction=#{jurisdiction_code} rate=#{rate}")
      {:ok, result}
    else
      true ->
        {:ok, %{taxable_amount: taxable_amount, rate: 0.0, tax_amount: 0.0, exempt: true}}

      {:error, _} = err ->
        err
    end
  end

  @spec effective_rate(String.t(), String.t()) :: {:ok, float()} | {:error, atom()}
  def effective_rate(jurisdiction_code, product_tax_code) do
    with {:ok, jurisdiction} <- TaxJurisdiction.fetch(jurisdiction_code) do
      rate = apply_product_modifier(jurisdiction.rate, product_tax_code)
      {:ok, rate}
    end
  end

  @spec annual_summary(String.t(), integer()) :: {:ok, map()} | {:error, atom()}
  def annual_summary(customer_id, year) do
    with {:ok, records} <- TaxAuditLog.fetch_for_year(customer_id, year) do
      total_tax =
        records
        |> Enum.map(& &1.tax_amount)
        |> Enum.sum()
        |> Float.round(@rounding_precision)

      {:ok,
       %{
         customer_id: customer_id,
         year: year,
         total_tax_paid: total_tax,
         transaction_count: length(records),
         by_jurisdiction: group_by_jurisdiction(records)
       }}
    end
  end

  # Private helpers

  defp validate_tax_type(type) when type in @supported_tax_types, do: :ok
  defp validate_tax_type(_), do: {:error, :unsupported_tax_type}

  defp check_minimum_amount(amount) when amount >= @minimum_taxable_amount, do: :ok
  defp check_minimum_amount(_), do: {:error, :amount_below_minimum}

  defp apply_product_modifier(base_rate, "FOOD"), do: base_rate * 0.5
  defp apply_product_modifier(base_rate, "DIGITAL"), do: base_rate * 1.2
  defp apply_product_modifier(base_rate, _), do: base_rate

  defp build_breakdown(amount, jurisdiction) do
    %{
      state_tax: Float.round(amount * jurisdiction.state_rate, @rounding_precision),
      county_tax: Float.round(amount * jurisdiction.county_rate, @rounding_precision),
      city_tax: Float.round(amount * Map.get(jurisdiction, :city_rate, 0.0), @rounding_precision)
    }
  end

  defp group_by_jurisdiction(records) do
    Enum.group_by(records, & &1.jurisdiction_code)
    |> Map.new(fn {jcode, recs} ->
      {jcode, Enum.sum(Enum.map(recs, & &1.tax_amount))}
    end)
  end

  defp apply_regional_rate(amount, rate, _region) do
    Float.round(amount * rate, @rounding_precision)
  end
end
```
