```elixir
defmodule ReportingDashboard do
  @moduledoc """
  Provides business analytics (revenue, churn, top products, user acquisition),
  multi-format data export, report caching, scheduled delivery, and email
  distribution for the platform's management dashboard.
  """

  require Logger
  import Ecto.Query
  alias Reporting.Repo
  alias Reporting.Order
  alias Reporting.User
  alias Reporting.Subscription
  alias Reporting.ReportCache
  alias Reporting.ScheduledReport

  @cache_ttl_seconds 3_600


  def revenue_summary(from_date, to_date) do
    rows =
      from(o in Order,
        where: o.status == :paid and o.paid_at >= ^from_date and o.paid_at <= ^to_date,
        group_by: fragment("date_trunc('day', ?)", o.paid_at),
        select: %{
          date: fragment("date_trunc('day', ?)", o.paid_at),
          total: sum(o.total),
          count: count(o.id)
        },
        order_by: [asc: fragment("date_trunc('day', ?)", o.paid_at)]
      )
      |> Repo.all()

    grand_total = Enum.reduce(rows, Decimal.new("0"), &Decimal.add(&2, &1.total))
    %{period: %{from: from_date, to: to_date}, daily: rows, grand_total: grand_total}
  end


  def churn_rate(from_date, to_date) do
    total_start =
      from(s in Subscription, where: s.started_at < ^from_date, select: count(s.id))
      |> Repo.one()

    churned =
      from(s in Subscription,
        where:
          s.cancelled_at >= ^from_date and
            s.cancelled_at <= ^to_date,
        select: count(s.id)
      )
      |> Repo.one()

    rate = if total_start > 0, do: Float.round(churned / total_start * 100, 2), else: 0.0
    %{period: %{from: from_date, to: to_date}, churned: churned, base: total_start, rate: rate}
  end


  def top_products(from_date, to_date, limit \\ 10) do
    from(o in Order,
      join: oi in assoc(o, :order_items),
      where: o.status == :paid and o.paid_at >= ^from_date and o.paid_at <= ^to_date,
      group_by: oi.product_id,
      order_by: [desc: sum(oi.quantity)],
      limit: ^limit,
      select: %{product_id: oi.product_id, units_sold: sum(oi.quantity), revenue: sum(oi.subtotal)}
    )
    |> Repo.all()
  end


  def user_acquisition(from_date, to_date) do
    rows =
      from(u in User,
        where: u.inserted_at >= ^from_date and u.inserted_at <= ^to_date,
        group_by: fragment("date_trunc('week', ?)", u.inserted_at),
        select: %{
          week: fragment("date_trunc('week', ?)", u.inserted_at),
          new_users: count(u.id)
        },
        order_by: [asc: fragment("date_trunc('week', ?)", u.inserted_at)]
      )
      |> Repo.all()

    total = Enum.sum(Enum.map(rows, & &1.new_users))
    %{period: %{from: from_date, to: to_date}, weekly: rows, total_new_users: total}
  end


  def export_to_csv(report_type, params) do
    data = run_report(report_type, params)
    rows = Map.get(data, :daily) || Map.get(data, :weekly) || data

    header =
      rows
      |> List.first(%{})
      |> Map.keys()
      |> Enum.join(",")

    lines =
      Enum.map(rows, fn row ->
        row |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(",")
      end)

    ([header] ++ lines) |> Enum.join("\n")
  end


  def export_to_json(report_type, params) do
    run_report(report_type, params) |> Jason.encode!()
  end

  defp run_report(:revenue, %{from: f, to: t}), do: revenue_summary(f, t)
  defp run_report(:churn, %{from: f, to: t}), do: churn_rate(f, t)
  defp run_report(:top_products, %{from: f, to: t}), do: top_products(f, t)
  defp run_report(:acquisition, %{from: f, to: t}), do: user_acquisition(f, t)


  def cache_report(report_type, params, ttl \\ @cache_ttl_seconds) do
    cache_key = "report:#{report_type}:#{:erlang.phash2(params)}"

    case Repo.get_by(ReportCache, cache_key: cache_key) do
      %{data: data, expires_at: exp} when exp > DateTime.utc_now() ->
        {:ok, Jason.decode!(data)}

      _ ->
        data = run_report(report_type, params)
        expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

        Repo.insert!(
          ReportCache.changeset(%ReportCache{}, %{
            cache_key: cache_key,
            data: Jason.encode!(data),
            expires_at: expires_at
          }),
          on_conflict: {:replace, [:data, :expires_at]},
          conflict_target: :cache_key
        )

        {:ok, data}
    end
  end


  def schedule_report_delivery(report_type, recipient_email, cron_expr) do
    attrs = %{
      report_type: to_string(report_type),
      recipient_email: recipient_email,
      cron_expression: cron_expr,
      active: true
    }

    case Repo.insert(ScheduledReport.changeset(%ScheduledReport{}, attrs)) do
      {:ok, sr} ->
        Logger.info("Scheduled #{report_type} report for #{recipient_email} (#{cron_expr})")
        {:ok, sr}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def send_report_email(report_type, params, recipient_email) do
    data = run_report(report_type, params)
    csv  = export_to_csv(report_type, params)

    body = """
    Please find the #{report_type} report attached for the period
    #{inspect(params[:from])} – #{inspect(params[:to])}.
    """

    case Mailer.deliver(%{
           to: recipient_email,
           subject: "#{report_type} Report — #{Date.utc_today()}",
           text_body: body,
           attachments: [%{filename: "#{report_type}_report.csv", content: csv}]
         }) do
      {:ok, _} ->
        Logger.info("Report email sent to #{recipient_email}")
        {:ok, data}

      {:error, reason} ->
        Logger.error("Failed to send report email: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```
