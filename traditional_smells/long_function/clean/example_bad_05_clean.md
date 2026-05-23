```elixir
defmodule Reporting.SalesReport do
  @moduledoc """
  Generates monthly sales reports aggregated by product category,
  including period-over-period growth metrics.
  """

  alias Reporting.{ReportStore, Repo}
  alias Sales.Order
  require Logger

  def generate_monthly(year, month) when is_integer(year) and month in 1..12 do
    Logger.info("Generating monthly sales report for #{year}-#{String.pad_leading("#{month}", 2, "0")}")

    # --- Build date range for target month ---
    {:ok, period_start} = Date.new(year, month, 1)
    days_in_month = Date.days_in_month(period_start)
    {:ok, period_end} = Date.new(year, month, days_in_month)

    # --- Build date range for previous month (for growth calc) ---
    {prev_year, prev_month} =
      if month == 1, do: {year - 1, 12}, else: {year, month - 1}

    {:ok, prev_start} = Date.new(prev_year, prev_month, 1)
    prev_days = Date.days_in_month(prev_start)
    {:ok, prev_end} = Date.new(prev_year, prev_month, prev_days)

    # --- Fetch orders for current month ---
    current_orders =
      Order
      |> Order.completed()
      |> Order.in_date_range(period_start, period_end)
      |> Repo.all()
      |> Repo.preload([:items])

    # --- Fetch orders for previous month ---
    previous_orders =
      Order
      |> Order.completed()
      |> Order.in_date_range(prev_start, prev_end)
      |> Repo.all()
      |> Repo.preload([:items])

    # --- Aggregate current month by category ---
    current_by_category =
      Enum.reduce(current_orders, %{}, fn order, acc ->
        Enum.reduce(order.items, acc, fn item, inner_acc ->
          category = item.category || "uncategorized"
          entry = Map.get(inner_acc, category, %{revenue: 0.0, units: 0})
          updated = %{
            revenue: entry.revenue + item.unit_price * item.quantity,
            units: entry.units + item.quantity
          }
          Map.put(inner_acc, category, updated)
        end)
      end)

    # --- Aggregate previous month by category ---
    previous_by_category =
      Enum.reduce(previous_orders, %{}, fn order, acc ->
        Enum.reduce(order.items, acc, fn item, inner_acc ->
          category = item.category || "uncategorized"
          entry = Map.get(inner_acc, category, %{revenue: 0.0, units: 0})
          updated = %{
            revenue: entry.revenue + item.unit_price * item.quantity,
            units: entry.units + item.quantity
          }
          Map.put(inner_acc, category, updated)
        end)
      end)

    # --- Compute growth per category ---
    all_categories = Map.keys(current_by_category) ++ Map.keys(previous_by_category)

    category_rows =
      all_categories
      |> Enum.uniq()
      |> Enum.map(fn cat ->
        curr = Map.get(current_by_category, cat, %{revenue: 0.0, units: 0})
        prev = Map.get(previous_by_category, cat, %{revenue: 0.0, units: 0})

        revenue_growth =
          if prev.revenue == 0.0 do
            nil
          else
            Float.round((curr.revenue - prev.revenue) / prev.revenue * 100, 2)
          end

        %{
          category: cat,
          current_revenue: curr.revenue,
          current_units: curr.units,
          previous_revenue: prev.revenue,
          previous_units: prev.units,
          revenue_growth_pct: revenue_growth
        }
      end)
      |> Enum.sort_by(& &1.current_revenue, :desc)

    # --- Build report payload ---
    total_current_revenue = Enum.reduce(category_rows, 0.0, &(&1.current_revenue + &2))
    total_previous_revenue = Enum.reduce(category_rows, 0.0, &(&1.previous_revenue + &2))

    overall_growth =
      if total_previous_revenue == 0.0, do: nil,
      else: Float.round((total_current_revenue - total_previous_revenue) / total_previous_revenue * 100, 2)

    report = %{
      period: "#{year}-#{String.pad_leading("#{month}", 2, "0")}",
      generated_at: DateTime.utc_now(),
      total_orders: length(current_orders),
      total_revenue: total_current_revenue,
      previous_revenue: total_previous_revenue,
      overall_growth_pct: overall_growth,
      categories: category_rows
    }

    # --- Persist report ---
    case ReportStore.save("monthly_sales_#{year}_#{month}", report) do
      :ok ->
        Logger.info("Monthly sales report saved for #{year}-#{month}")
        {:ok, report}

      {:error, reason} ->
        Logger.error("Failed to save monthly sales report: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```
