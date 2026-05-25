```elixir
defmodule Reporting.SalesReport do
  @moduledoc """
  Generates sales performance reports for the business intelligence dashboard.
  Reports are grouped by configurable time windows and optionally filtered
  by team, product line, or customer segment.
  """

  alias Reporting.{Sale, Customer, Product}
  alias Reporting.Repo

  @default_window_days 30

  def build(%{breakdown_by: breakdown_by} = params) do
    from_date  = Map.get(params, :from_date, default_from_date())
    to_date    = Map.get(params, :to_date, Date.utc_today())
    team_id    = Map.get(params, :team_id)
    segment    = Map.get(params, :customer_segment)

    sales =
      Sale
      |> Repo.all()
      |> Enum.filter(fn s ->
        within_range?(s.sale_date, from_date, to_date) and
          matches_team?(s, team_id) and
          matches_segment?(s, segment)
      end)

    grouped =
      case breakdown_by do
        _ ->
          Enum.group_by(sales, &Date.beginning_of_week(&1.sale_date))
      end

    totals =
      Map.new(grouped, fn {period, period_sales} ->
        revenue = Enum.reduce(period_sales, 0.0, fn s, acc -> acc + s.amount end)
        {period, Float.round(revenue, 2)}
      end)

    summary = build_summary(sales)

    {:ok, %{totals: totals, summary: summary, params: params}}
  end

  def build(params) do
    build(Map.put(params, :breakdown_by, :date))
  end

  def top_performers(limit \\ 10) do
    Sale
    |> Repo.all()
    |> Enum.group_by(& &1.sales_rep_id)
    |> Enum.map(fn {rep_id, rep_sales} ->
      total = Enum.reduce(rep_sales, 0.0, fn s, acc -> acc + s.amount end)
      %{sales_rep_id: rep_id, total_revenue: Float.round(total, 2), count: length(rep_sales)}
    end)
    |> Enum.sort_by(& &1.total_revenue, :desc)
    |> Enum.take(limit)
  end

  def conversion_rate(from_date, to_date) do
    leads = Repo.count_leads(from_date, to_date)
    sales = Repo.count_sales(from_date, to_date)

    if leads > 0 do
      Float.round(sales / leads * 100, 1)
    else
      0.0
    end
  end

  def product_breakdown(from_date, to_date) do
    Sale
    |> Repo.all()
    |> Enum.filter(&within_range?(&1.sale_date, from_date, to_date))
    |> Enum.group_by(& &1.product_id)
    |> Enum.map(fn {product_id, product_sales} ->
      product = Repo.get!(Product, product_id)
      total   = Enum.reduce(product_sales, 0.0, fn s, acc -> acc + s.amount end)
      %{product: product.name, total_revenue: Float.round(total, 2), units_sold: length(product_sales)}
    end)
    |> Enum.sort_by(& &1.total_revenue, :desc)
  end

  def export_csv(report_data) do
    header = "period,revenue\n"

    rows =
      report_data.totals
      |> Enum.sort_by(fn {period, _} -> period end)
      |> Enum.map(fn {period, revenue} -> "#{period},#{revenue}" end)
      |> Enum.join("\n")

    {:ok, header <> rows}
  end


  defp build_summary(sales) do
    %{
      total_revenue: sales |> Enum.reduce(0.0, &(&1.amount + &2)) |> Float.round(2),
      total_sales:   length(sales),
      avg_sale:      if(length(sales) > 0, do: Float.round(Enum.sum(Enum.map(sales, & &1.amount)) / length(sales), 2), else: 0.0)
    }
  end

  defp within_range?(date, from, to) do
    Date.compare(date, from) in [:gt, :eq] and
      Date.compare(date, to) in [:lt, :eq]
  end

  defp matches_team?(_sale, nil), do: true
  defp matches_team?(sale, team_id), do: sale.team_id == team_id

  defp matches_segment?(_sale, nil), do: true
  defp matches_segment?(sale, segment), do: sale.customer_segment == segment

  defp default_from_date do
    Date.add(Date.utc_today(), -@default_window_days)
  end
end
```
