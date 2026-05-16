# Example 36: Real Estate Property Valuation System

```elixir
defmodule RealEstate.PropertyValuation do
  @moduledoc """
  Handles property appraisals, comparative market analysis,
  and automated valuation models for residential listings.
  """

  alias RealEstate.{Property, Comparable, MarketData, ValuationReport, AuditLog}

  @adjustment_keys [:lot_size, :square_footage, :bedrooms, :bathrooms, :garage, :pool, :year_built]

  def generate_automated_valuation(property_id) do
    with {:ok, property} <- Property.get(property_id),
         {:ok, comparables} <- find_comparable_properties(property),
         {:ok, market_trends} <- MarketData.get_trends(property.zip_code) do

      base_value = median_sale_price(comparables)
      trend_factor = compute_trend_factor(market_trends)

      estimated_value = Float.round(base_value * trend_factor, 2)
      confidence = compute_confidence(comparables)

      report = %ValuationReport{
        property_id: property_id,
        estimated_value: estimated_value,
        confidence_score: confidence,
        methodology: :automated,
        generated_at: DateTime.utc_now()
      }

      {:ok, _} = ValuationReport.insert(report)
      {:ok, report}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def calculate_appraisal(property_id, comparable_ids, adjustments) do
    with {:ok, property} <- Property.get(property_id),
         {:ok, comparables} <- fetch_comparables(comparable_ids),
         :ok <- validate_comparables_coverage(comparables, property) do

      base_price = median_sale_price(comparables)

      adjusted_price = apply_adjustments(base_price, adjustments)

      per_sqft = adjusted_price / property.square_footage

      report = %ValuationReport{
        property_id: property_id,
        estimated_value: Float.round(adjusted_price, 2),
        price_per_sqft: Float.round(per_sqft, 2),
        comparable_ids: comparable_ids,
        adjustments_applied: adjustments,
        methodology: :manual_cma,
        generated_at: DateTime.utc_now()
      }

      {:ok, _} = ValuationReport.insert(report)
      {:ok, _} = AuditLog.record(:appraisal_created, property_id, %{report_id: report.id})

      {:ok, report}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def compare_properties(property_id_a, property_id_b) do
    with {:ok, prop_a} <- Property.get(property_id_a),
         {:ok, prop_b} <- Property.get(property_id_b),
         {:ok, report_a} <- ValuationReport.latest_for(property_id_a),
         {:ok, report_b} <- ValuationReport.latest_for(property_id_b) do

      diff = report_a.estimated_value - report_b.estimated_value
      pct_diff = diff / report_b.estimated_value * 100.0

      comparison = %{
        property_a: %{id: property_id_a, value: report_a.estimated_value, sqft: prop_a.square_footage},
        property_b: %{id: property_id_b, value: report_b.estimated_value, sqft: prop_b.square_footage},
        absolute_difference: Float.round(diff, 2),
        percentage_difference: Float.round(pct_diff, 2),
        higher_valued: if(diff >= 0, do: property_id_a, else: property_id_b)
      }

      {:ok, comparison}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_undervalued_properties(zip_code, threshold_pct \\ 10.0) do
    with {:ok, market} <- MarketData.get_trends(zip_code),
         {:ok, properties} <- Property.list_by_zip(zip_code) do

      median = market.median_sale_price

      undervalued =
        properties
        |> Enum.filter(fn p ->
          case ValuationReport.latest_for(p.id) do
            {:ok, r} -> r.estimated_value < median * (1 - threshold_pct / 100)
            _ -> false
          end
        end)
        |> Enum.map(&summarize_property/1)

      {:ok, undervalued}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_valuations_for_zip(zip_code) do
    with {:ok, properties} <- Property.list_by_zip(zip_code) do
      results =
        Enum.map(properties, fn p ->
          case generate_automated_valuation(p.id) do
            {:ok, report} -> {:ok, p.id, report.estimated_value}
            {:error, reason} -> {:error, p.id, reason}
          end
        end)

      successes = Enum.count(results, &match?({:ok, _, _}, &1))
      failures = Enum.count(results, &match?({:error, _, _}, &1))

      {:ok, %{total: length(properties), refreshed: successes, failed: failures}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_adjustments(base_price, adjustments) do
    Enum.reduce(adjustments, base_price, fn {key, value}, acc ->
      weight = Map.get(adjustment_weights(), key, 0.0)
      acc + value * weight
    end)
  end

  defp adjustment_weights do
    %{
      lot_size: 15.0,
      square_footage: 120.0,
      bedrooms: 8_500.0,
      bathrooms: 6_200.0,
      garage: 12_000.0,
      pool: 22_000.0,
      year_built: 800.0
    }
  end

  defp find_comparable_properties(property) do
    Comparable.search(%{
      zip_code: property.zip_code,
      min_sqft: property.square_footage * 0.8,
      max_sqft: property.square_footage * 1.2,
      sold_within_days: 180
    })
  end

  defp fetch_comparables(comparable_ids) do
    results = Enum.map(comparable_ids, &Comparable.get/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, c} -> c end)}
    else
      {:error, :some_comparables_not_found}
    end
  end

  defp validate_comparables_coverage(comparables, _property) do
    if length(comparables) >= 3 do
      :ok
    else
      {:error, :insufficient_comparables}
    end
  end

  defp median_sale_price(comparables) do
    prices = Enum.map(comparables, & &1.sale_price) |> Enum.sort()
    mid = div(length(prices), 2)
    Enum.at(prices, mid)
  end

  defp compute_trend_factor(%{monthly_appreciation_rate: rate, months: months}) do
    :math.pow(1 + rate, months)
  end

  defp compute_confidence(comparables) do
    cond do
      length(comparables) >= 10 -> :high
      length(comparables) >= 5 -> :medium
      true -> :low
    end
  end

  defp summarize_property(property) do
    %{id: property.id, address: property.address, list_price: property.list_price}
  end
end
```
