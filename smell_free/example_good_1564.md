```elixir
defmodule Billing.Invoices.LineItemCalculator do
  @moduledoc """
  Computes invoice line item totals applying tiered pricing and
  usage-based adjustments for billing period summaries.
  """

  alias Billing.Invoices.{LineItem, TieredRate, UsageRecord}

  @type calculation_result :: %{
          line_item_id: String.t(),
          base_units: non_neg_integer(),
          billable_units: non_neg_integer(),
          unit_rate: Decimal.t(),
          subtotal: Decimal.t(),
          adjustments: [adjustment()]
        }

  @type adjustment :: %{
          label: String.t(),
          amount: Decimal.t()
        }

  @doc """
  Calculates the billing total for a single line item given usage records.

  Returns a full breakdown including base units, billable units, applied
  rate tier, and any overage or discount adjustments.
  """
  @spec calculate(LineItem.t(), [UsageRecord.t()]) :: calculation_result()
  def calculate(%LineItem{} = item, usage_records) when is_list(usage_records) do
    base_units = sum_base_units(usage_records)
    billable_units = apply_included_allowance(base_units, item.included_units)
    rate = resolve_rate_tier(item.tiered_rates, billable_units)
    subtotal = Decimal.mult(Decimal.new(billable_units), rate.unit_price)
    adjustments = compute_adjustments(item, billable_units, subtotal)
    adjusted_subtotal = apply_adjustments(subtotal, adjustments)

    %{
      line_item_id: item.id,
      base_units: base_units,
      billable_units: billable_units,
      unit_rate: rate.unit_price,
      subtotal: adjusted_subtotal,
      adjustments: adjustments
    }
  end

  @doc """
  Aggregates calculation results into a single invoice subtotal.
  """
  @spec aggregate_subtotal([calculation_result()]) :: Decimal.t()
  def aggregate_subtotal(results) when is_list(results) do
    Enum.reduce(results, Decimal.new("0"), fn result, acc ->
      Decimal.add(acc, result.subtotal)
    end)
  end

  defp sum_base_units(usage_records) do
    Enum.reduce(usage_records, 0, fn %UsageRecord{quantity: qty}, acc -> acc + qty end)
  end

  defp apply_included_allowance(total_units, included) when total_units <= included, do: 0
  defp apply_included_allowance(total_units, included), do: total_units - included

  defp resolve_rate_tier(tiered_rates, units) do
    tiered_rates
    |> Enum.sort_by(& &1.threshold, :desc)
    |> Enum.find(fn %TieredRate{threshold: threshold} -> units >= threshold end)
    |> case do
      nil -> List.last(Enum.sort_by(tiered_rates, & &1.threshold))
      rate -> rate
    end
  end

  defp compute_adjustments(%LineItem{overage_rate: nil}, _units, _subtotal), do: []

  defp compute_adjustments(%LineItem{overage_threshold: threshold, overage_rate: rate}, units, _subtotal)
       when units > threshold do
    overage_units = units - threshold
    overage_amount = Decimal.mult(Decimal.new(overage_units), rate)
    [%{label: "Overage charge", amount: overage_amount}]
  end

  defp compute_adjustments(%LineItem{}, _units, _subtotal), do: []

  defp apply_adjustments(subtotal, adjustments) do
    Enum.reduce(adjustments, subtotal, fn %{amount: amount}, acc ->
      Decimal.add(acc, amount)
    end)
  end
end
```
