```elixir
defmodule Inventory.ReorderAdvisor do
  @moduledoc """
  Analyses current stock levels against historical sales velocity and
  recommends reorder quantities for SKUs approaching their reorder point.
  All logic is pure and stateless, operating on data supplied by callers
  so the module has no database or process dependency.
  """

  @type sku :: String.t()
  @type stock_snapshot :: %{sku: sku(), on_hand: non_neg_integer(), reorder_point: non_neg_integer(), lead_days: pos_integer()}
  @type sales_record :: %{sku: sku(), quantity: pos_integer(), sold_on: Date.t()}
  @type recommendation :: %{
          sku: sku(),
          on_hand: non_neg_integer(),
          daily_velocity: float(),
          days_remaining: float(),
          suggested_quantity: non_neg_integer()
        }

  @analysis_window_days 30
  @safety_stock_days 7

  @doc """
  Returns reorder recommendations for SKUs whose projected days-remaining
  stock falls at or below their reorder trigger. Accepts a reference date
  so computations are reproducible in tests.
  """
  @spec recommend([stock_snapshot()], [sales_record()], Date.t()) :: [recommendation()]
  def recommend(snapshots, sales_records, reference_date \ Date.utc_today())
      when is_list(snapshots) and is_list(sales_records) do
    velocity_map = compute_velocities(sales_records, reference_date)

    snapshots
    |> Enum.map(fn snap -> build_recommendation(snap, velocity_map) end)
    |> Enum.filter(fn rec -> rec.days_remaining <= rec_threshold(rec) end)
    |> Enum.sort_by(& &1.days_remaining)
  end

  @doc "Computes the average daily sales velocity per SKU over the analysis window."
  @spec compute_velocities([sales_record()], Date.t()) :: %{sku() => float()}
  def compute_velocities(sales_records, reference_date) do
    cutoff = Date.add(reference_date, -@analysis_window_days)

    sales_records
    |> Enum.filter(fn r -> Date.compare(r.sold_on, cutoff) != :lt end)
    |> Enum.group_by(& &1.sku)
    |> Map.new(fn {sku, records} ->
      total = Enum.sum_by(records, & &1.quantity)
      {sku, total / @analysis_window_days}
    end)
  end

  defp build_recommendation(%{sku: sku, on_hand: on_hand, lead_days: lead_days} = snap, velocity_map) do
    velocity = Map.get(velocity_map, sku, 0.0)
    days_remaining = if velocity > 0, do: on_hand / velocity, else: 999.0
    suggested = max(0, round(velocity * (lead_days + @safety_stock_days) - on_hand))

    %{
      sku: sku,
      on_hand: on_hand,
      daily_velocity: Float.round(velocity, 2),
      days_remaining: Float.round(days_remaining, 1),
      suggested_quantity: suggested
    }
  end

  defp rec_threshold(%{daily_velocity: v}) when v > 0 do
    @safety_stock_days * 2.0
  end

  defp rec_threshold(_), do: 0.0
end
```
