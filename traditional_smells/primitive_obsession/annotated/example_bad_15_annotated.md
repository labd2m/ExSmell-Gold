# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `apply_tax/4`, `calculate_inclusive_tax/3`, `build_tax_line/4`, `effective_tax_rate/2`
- **Affected Function(s)**: All public functions in `Billing.TaxEngine`
- **Explanation**: A tax configuration is passed as separate `float()` rate and `String.t()` name/jurisdiction primitives rather than a `%TaxPolicy{name: String.t(), rate: float(), jurisdiction: String.t(), inclusive: boolean()}` struct. This means every function must receive and validate multiple unrelated primitives, the inclusive/exclusive distinction is an extra boolean parameter, and there is nothing preventing a caller from mixing up rate and jurisdiction arguments.

## Code

```elixir
defmodule Billing.TaxEngine do
  @moduledoc """
  Computes tax amounts for invoices and individual line items.
  Supports both tax-exclusive and tax-inclusive pricing models
  across multiple jurisdictions.
  """

  require Logger

  @max_combined_rate 0.50
  @rounding_precision 2

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because a tax policy is modelled as three separate
  # VALIDATION: primitives — `rate :: float()`, `tax_name :: String.t()`, and
  # VALIDATION: `jurisdiction :: String.t()` — instead of a
  # VALIDATION: `%TaxPolicy{name: String.t(), rate: float(), jurisdiction: String.t(),
  # VALIDATION: inclusive: boolean()}` struct. The `inclusive` flag is an extra
  # VALIDATION: boolean parameter, the rate has no ownership or expiry, and callers
  # VALIDATION: must manage four related values in tandem across every call.
  @spec apply_tax(float(), float(), String.t(), boolean()) ::
          {:ok, map()} | {:error, String.t()}
  def apply_tax(amount, rate, tax_name, inclusive \\ false)
      when is_float(amount) and is_float(rate) and is_binary(tax_name) do
    with :ok <- validate_rate(rate),
         :ok <- validate_amount(amount) do
      {tax_amount, net_amount, gross_amount} =
        if inclusive do
          net = Float.round(amount / (1.0 + rate), @rounding_precision)
          tax = Float.round(amount - net, @rounding_precision)
          {tax, net, amount}
        else
          tax = Float.round(amount * rate, @rounding_precision)
          gross = Float.round(amount + tax, @rounding_precision)
          {tax, amount, gross}
        end

      {:ok,
       %{
         net_amount: net_amount,
         tax_amount: tax_amount,
         gross_amount: gross_amount,
         rate: rate,
         tax_name: tax_name,
         inclusive: inclusive
       }}
    end
  end

  @spec calculate_inclusive_tax(float(), float(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def calculate_inclusive_tax(gross_amount, rate, tax_name) do
    apply_tax(gross_amount, rate, tax_name, true)
  end

  @spec build_tax_line(float(), float(), String.t(), String.t()) :: map()
  def build_tax_line(taxable_amount, rate, tax_name, jurisdiction) do
    tax_amount = Float.round(taxable_amount * rate, @rounding_precision)

    %{
      description: "#{tax_name} (#{jurisdiction})",
      taxable_amount: taxable_amount,
      rate: rate,
      tax_amount: tax_amount,
      jurisdiction: jurisdiction
    }
  end

  @spec effective_tax_rate(float(), list({float(), String.t()})) ::
          {:ok, float()} | {:error, String.t()}
  def effective_tax_rate(base_amount, tax_components) do
    total_tax =
      tax_components
      |> Enum.reduce(0.0, fn {rate, _name}, acc ->
        acc + base_amount * rate
      end)
      |> Float.round(@rounding_precision)

    combined_rate =
      tax_components
      |> Enum.map(fn {rate, _} -> rate end)
      |> Enum.sum()

    if combined_rate > @max_combined_rate do
      {:error,
       "Combined tax rate #{combined_rate} exceeds maximum allowed #{@max_combined_rate}"}
    else
      {:ok, Float.round(combined_rate, 4)}
    end
  end

  @spec summarise_tax_lines(list(map())) :: map()
  def summarise_tax_lines(tax_lines) do
    total_tax = tax_lines |> Enum.map(& &1.tax_amount) |> Enum.sum() |> Float.round(2)
    total_taxable = tax_lines |> Enum.map(& &1.taxable_amount) |> Enum.sum() |> Float.round(2)

    Logger.debug("Tax summary: #{total_taxable} taxable, #{total_tax} total tax")

    %{
      line_count: length(tax_lines),
      total_taxable_amount: total_taxable,
      total_tax_amount: total_tax,
      effective_rate: if(total_taxable > 0, do: Float.round(total_tax / total_taxable, 4), else: 0.0)
    }
  end
  # VALIDATION: SMELL END

  defp validate_rate(rate) do
    cond do
      rate < 0.0 ->
        {:error, "Tax rate cannot be negative: #{rate}"}

      rate > @max_combined_rate ->
        {:error, "Single tax rate #{rate} exceeds maximum #{@max_combined_rate}"}

      true ->
        :ok
    end
  end

  defp validate_amount(amount) do
    if amount >= 0.0 do
      :ok
    else
      {:error, "Taxable amount cannot be negative: #{amount}"}
    end
  end
end
```
