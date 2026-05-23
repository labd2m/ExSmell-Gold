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
