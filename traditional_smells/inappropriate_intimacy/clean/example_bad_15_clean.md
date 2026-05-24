```elixir
defmodule MyApp.Reporting.SalesReportBuilder do
  @moduledoc """
  Compiles regional sales reports for a given time range.
  Supports configurable metrics, currency normalization, and fiscal calendar alignment.
  """

  alias MyApp.Reporting.{ReportConfig, SalesRegion, ReportExporter}
  alias MyApp.Sales.{Order, Representative}
  alias MyApp.Finance.CurrencyConverter

  def build(region_id, config_id) do
    with {:ok, region} <- SalesRegion.fetch(region_id),
         {:ok, config} <- ReportConfig.fetch(config_id) do

      team_ids         = region.team_ids
      currency_code    = region.currency_code
      conversion_rates = region.conversion_rates

      metrics          = config.included_metrics
      aggregation      = config.aggregation_level
      fy_start         = config.fiscal_year_start

      range = fiscal_range(fy_start)

      orders =
        team_ids
        |> Enum.flat_map(&Order.list_for_team(&1, range))
        |> Enum.map(&normalize_currency(&1, currency_code, conversion_rates))

      reps   = Enum.flat_map(team_ids, &Representative.list_for_team/1)
      rows   = aggregate(orders, reps, aggregation, metrics)

      report = %{
        id:              generate_id(),
        region_id:       region_id,
        config_id:       config_id,
        currency:        currency_code,
        period:          range,
        aggregation:     aggregation,
        metrics:         metrics,
        rows:            rows,
        generated_at:    DateTime.utc_now()
      }

      {:ok, report}
    end
  end

  def export(report, format \\ :csv) do
    ReportExporter.export(report, format)
  end

  def schedule(region_id, config_id, cron_expr) do
    job = %{
      region_id:  region_id,
      config_id:  config_id,
      cron:       cron_expr,
      enabled:    true,
      created_at: DateTime.utc_now()
    }
    :ets.insert(:report_schedules, {generate_id(), job})
    {:ok, job}
  end


  defp fiscal_range(fy_start) do
    today = Date.utc_today()
    year  = if Date.compare(today, fy_start) == :gt, do: today.year, else: today.year - 1
    start = %{fy_start | year: year}
    stop  = Date.add(start, 364)
    {DateTime.new!(start, ~T[00:00:00]), DateTime.new!(stop, ~T[23:59:59])}
  end

  defp normalize_currency(order, target_currency, rates) do
    if order.currency == target_currency do
      order
    else
      rate = Map.get(rates, order.currency, 1.0)
      %{order | amount: Float.round(order.amount * rate, 2), currency: target_currency}
    end
  end

  defp aggregate(orders, reps, level, metrics) do
    rep_index = Map.new(reps, &{&1.id, &1})
    groups    = group_by_level(orders, level)

    Enum.map(groups, fn {key, grouped_orders} ->
      base = %{group: key, order_count: length(grouped_orders)}

      Enum.reduce(metrics, base, fn metric, row ->
        Map.put(row, metric, compute_metric(metric, grouped_orders, rep_index))
      end)
    end)
  end

  defp group_by_level(orders, :daily),    do: Enum.group_by(orders, &Date.to_string(DateTime.to_date(&1.placed_at)))
  defp group_by_level(orders, :weekly),   do: Enum.group_by(orders, &Calendar.ISO.week_of_year(DateTime.to_date(&1.placed_at)))
  defp group_by_level(orders, :monthly),  do: Enum.group_by(orders, &{&1.placed_at.year, &1.placed_at.month})
  defp group_by_level(orders, _),         do: [{"all", orders}]

  defp compute_metric(:total_revenue, orders, _),    do: orders |> Enum.map(& &1.amount) |> Enum.sum()
  defp compute_metric(:avg_order_value, orders, _),  do: if(orders == [], do: 0, else: Enum.sum(Enum.map(orders, & &1.amount)) / length(orders))
  defp compute_metric(:unique_customers, orders, _), do: orders |> Enum.map(& &1.customer_id) |> Enum.uniq() |> length()
  defp compute_metric(_, _, _), do: nil

  defp generate_id do
    "RPT-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
