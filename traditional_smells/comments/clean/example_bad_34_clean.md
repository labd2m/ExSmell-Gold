```elixir
defmodule MyApp.ReportGenerator do
  @moduledoc """
  Builds aggregated sales, revenue, and churn reports for the
  MyApp analytics dashboard and scheduled exports.
  """

  alias MyApp.Repo
  alias MyApp.Reporting.{SalesRecord, ReportCache}
  alias MyApp.Accounts.User

  require Logger

  @cache_ttl_seconds 600

  @doc """
  Returns a list of top-selling products within the given date range,
  limited to `n` results.
  """
  def top_products(date_from, date_to, n \\ 10) do
    SalesRecord
    |> SalesRecord.between(date_from, date_to)
    |> SalesRecord.group_by_product()
    |> SalesRecord.order_by_revenue(:desc)
    |> SalesRecord.limit(n)
    |> Repo.all()
  end


  # generate_sales_report/2
  #
  # Produces a complete sales summary report for the given date range.
  #
  # The report is a map containing:
  #   :period_from       — the start date of the report
  #   :period_to         — the end date of the report
  #   :total_orders      — number of completed orders
  #   :total_revenue     — total revenue as a Decimal
  #   :average_order_value — average revenue per order as a Decimal
  #   :top_products      — top 5 selling products by revenue
  #   :new_customers     — count of first-time buyers in the period
  #   :returning_customers — count of repeat buyers in the period
  #   :generated_at      — UTC datetime of report generation
  #
  # Results are cached for @cache_ttl_seconds seconds under a key derived
  # from the date range. Pass `force_refresh: true` in opts to bypass cache.
  #
  # Returns:
  #   {:ok, report_map}
  #   {:error, reason} on data access failure
  def generate_sales_report(date_from, date_to, opts \\ []) do
    cache_key = "sales_report_#{Date.to_iso8601(date_from)}_#{Date.to_iso8601(date_to)}"
    force = Keyword.get(opts, :force_refresh, false)

    if not force do
      case fetch_from_cache(cache_key) do
        {:ok, cached} -> {:ok, cached}
        :miss -> build_and_cache_report(date_from, date_to, cache_key)
      end
    else
      build_and_cache_report(date_from, date_to, cache_key)
    end
  end

  @doc """
  Exports the sales report for the given period as a CSV binary.

  Returns `{:ok, csv_binary}` or `{:error, reason}`.
  """
  def export_csv(date_from, date_to) do
    with {:ok, report} <- generate_sales_report(date_from, date_to) do
      csv =
        [report_headers()]
        |> Enum.concat(report_rows(report))
        |> Enum.map_join("\n", &Enum.join(&1, ","))

      {:ok, csv}
    end
  end

  # --- Private helpers ---

  defp build_and_cache_report(date_from, date_to, cache_key) do
    Logger.info("Building sales report #{cache_key}")

    with {:ok, summary} <- fetch_order_summary(date_from, date_to),
         {:ok, customer_data} <- fetch_customer_breakdown(date_from, date_to),
         {:ok, products} <- {:ok, top_products(date_from, date_to, 5)} do
      report = %{
        period_from: date_from,
        period_to: date_to,
        total_orders: summary.total_orders,
        total_revenue: summary.total_revenue,
        average_order_value: compute_aov(summary),
        top_products: products,
        new_customers: customer_data.new_customers,
        returning_customers: customer_data.returning_customers,
        generated_at: DateTime.utc_now()
      }

      store_in_cache(cache_key, report)
      {:ok, report}
    end
  end

  defp fetch_order_summary(date_from, date_to) do
    result =
      SalesRecord
      |> SalesRecord.between(date_from, date_to)
      |> SalesRecord.completed()
      |> SalesRecord.summary_aggregate()
      |> Repo.one()

    {:ok, result || %{total_orders: 0, total_revenue: Decimal.new(0)}}
  end

  defp fetch_customer_breakdown(date_from, date_to) do
    new_count =
      User
      |> User.first_purchase_between(date_from, date_to)
      |> Repo.aggregate(:count, :id)

    returning_count =
      User
      |> User.repeat_purchase_between(date_from, date_to)
      |> Repo.aggregate(:count, :id)

    {:ok, %{new_customers: new_count, returning_customers: returning_count}}
  end

  defp compute_aov(%{total_orders: 0}), do: Decimal.new(0)

  defp compute_aov(%{total_orders: n, total_revenue: rev}) do
    Decimal.div(rev, Decimal.new(n))
  end

  defp fetch_from_cache(key) do
    case Repo.get_by(ReportCache, cache_key: key) do
      nil ->
        :miss

      %ReportCache{expires_at: exp, data: data} ->
        if DateTime.before?(DateTime.utc_now(), exp) do
          {:ok, data}
        else
          :miss
        end
    end
  end

  defp store_in_cache(key, data) do
    expires_at = DateTime.add(DateTime.utc_now(), @cache_ttl_seconds, :second)

    %ReportCache{}
    |> ReportCache.changeset(%{cache_key: key, data: data, expires_at: expires_at})
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :cache_key)
  end

  defp report_headers do
    ["period_from", "period_to", "total_orders", "total_revenue", "avg_order_value"]
  end

  defp report_rows(report) do
    [
      [
        Date.to_iso8601(report.period_from),
        Date.to_iso8601(report.period_to),
        report.total_orders,
        Decimal.to_string(report.total_revenue),
        Decimal.to_string(report.average_order_value)
      ]
    ]
  end
end
```
