# Annotated Example — Large Module (Large Class)

| Field | Value |
|---|---|
| **Smell name** | Large Module (Large Class) |
| **Expected smell location** | `ReportingEngine` module (entire module) |
| **Affected functions** | All functions: revenue reports, user growth, funnel analytics, export, and scheduling |
| **Short explanation** | `ReportingEngine` aggregates revenue reporting, user growth analytics, conversion funnel analysis, multi-format export, and report scheduling — five unrelated reporting concerns merged into one module. |

```elixir
# VALIDATION: SMELL START - Large Module (Large Class)
# VALIDATION: This is a smell because ReportingEngine handles revenue aggregation,
# user growth analytics, funnel conversion metrics, CSV/PDF export logic, and
# scheduled report delivery — each a distinct reporting concern that should
# live in a dedicated module instead of sharing one large non-cohesive module.
defmodule ReportingEngine do
  @moduledoc """
  Generates, exports, and schedules business intelligence reports.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Reporting.{ScheduledReport, ReportExport}
  alias MyApp.Payments.Payment
  alias MyApp.Accounts.User
  alias MyApp.Orders.Order
  alias MyApp.Mailer

  @default_currency "USD"
  @export_base_path "/var/reports"

  # --- Revenue Reports ---

  def revenue_by_period(from_date, to_date, group_by \\ :day) do
    payments =
      Repo.all(
        from p in Payment,
          where:
            p.status == :succeeded and
              fragment("DATE(?)", p.processed_at) >= ^from_date and
              fragment("DATE(?)", p.processed_at) <= ^to_date,
          select: %{amount: p.amount, processed_at: p.processed_at, currency: p.currency}
      )

    payments
    |> Enum.group_by(fn %{processed_at: dt} -> group_key(dt, group_by) end)
    |> Enum.map(fn {period, entries} ->
      total = Enum.reduce(entries, Decimal.new(0), &Decimal.add(&2, &1.amount))
      %{period: period, total: total, count: length(entries), currency: @default_currency}
    end)
    |> Enum.sort_by(& &1.period)
  end

  def revenue_by_product(from_date, to_date) do
    Repo.all(
      from o in Order,
        join: p in Payment,
        on: p.order_id == o.id,
        where:
          p.status == :succeeded and
            fragment("DATE(?)", p.processed_at) >= ^from_date and
            fragment("DATE(?)", p.processed_at) <= ^to_date,
        group_by: o.product_id,
        select: %{
          product_id: o.product_id,
          total_revenue: sum(p.amount),
          order_count: count(o.id)
        }
    )
  end

  defp group_key(dt, :day), do: DateTime.to_date(dt)
  defp group_key(dt, :month), do: {dt.year, dt.month}
  defp group_key(dt, :week), do: Timex.iso_week(dt)

  # --- User Growth Analytics ---

  def user_growth(from_date, to_date) do
    registrations =
      Repo.all(
        from u in User,
          where:
            fragment("DATE(?)", u.inserted_at) >= ^from_date and
              fragment("DATE(?)", u.inserted_at) <= ^to_date,
          group_by: fragment("DATE(?)", u.inserted_at),
          select: %{date: fragment("DATE(?)", u.inserted_at), new_users: count(u.id)}
      )

    churn =
      Repo.all(
        from u in User,
          where:
            u.deactivated_at != nil and
              fragment("DATE(?)", u.deactivated_at) >= ^from_date and
              fragment("DATE(?)", u.deactivated_at) <= ^to_date,
          group_by: fragment("DATE(?)", u.deactivated_at),
          select: %{date: fragment("DATE(?)", u.deactivated_at), churned_users: count(u.id)}
      )

    merge_growth_and_churn(registrations, churn)
  end

  defp merge_growth_and_churn(registrations, churn) do
    churn_map = Map.new(churn, &{&1.date, &1.churned_users})

    Enum.map(registrations, fn reg ->
      Map.put(reg, :churned_users, Map.get(churn_map, reg.date, 0))
    end)
  end

  def cumulative_users(as_of_date) do
    Repo.one(
      from u in User,
        where: fragment("DATE(?)", u.inserted_at) <= ^as_of_date,
        select: count(u.id)
    )
  end

  # --- Funnel Analytics ---

  def conversion_funnel(from_date, to_date) do
    visitors = count_events(:page_view, from_date, to_date)
    sign_ups = count_events(:sign_up, from_date, to_date)
    trial_starts = count_events(:trial_start, from_date, to_date)
    conversions = count_events(:subscription_created, from_date, to_date)

    %{
      visitors: visitors,
      sign_ups: sign_ups,
      trial_starts: trial_starts,
      conversions: conversions,
      visitor_to_signup: safe_rate(sign_ups, visitors),
      signup_to_trial: safe_rate(trial_starts, sign_ups),
      trial_to_paid: safe_rate(conversions, trial_starts)
    }
  end

  defp count_events(event_type, from_date, to_date) do
    Repo.one(
      from e in MyApp.Analytics.Event,
        where:
          e.type == ^event_type and
            fragment("DATE(?)", e.occurred_at) >= ^from_date and
            fragment("DATE(?)", e.occurred_at) <= ^to_date,
        select: count(e.id)
    ) || 0
  end

  defp safe_rate(_, 0), do: 0.0
  defp safe_rate(num, denom), do: Float.round(num / denom * 100, 2)

  # --- Export ---

  def export_revenue_csv(from_date, to_date) do
    rows = revenue_by_period(from_date, to_date)
    filename = "revenue_#{from_date}_#{to_date}.csv"
    path = Path.join(@export_base_path, filename)

    header = "period,total,count,currency\n"

    body =
      Enum.map_join(rows, "\n", fn r ->
        "#{r.period},#{r.total},#{r.count},#{r.currency}"
      end)

    :ok = File.write(path, header <> body)
    Logger.info("Revenue CSV exported to #{path}")
    {:ok, path}
  end

  def export_growth_pdf(from_date, to_date) do
    data = user_growth(from_date, to_date)
    filename = "growth_#{from_date}_#{to_date}.pdf"
    path = Path.join(@export_base_path, filename)

    content = Enum.map_join(data, "\n", fn row ->
      "#{row.date}: +#{row.new_users} users, -#{row.churned_users} churned"
    end)

    File.write(path, content)
    {:ok, path}
  end

  # --- Scheduled Reports ---

  def schedule_report(report_type, recipient_email, cron_expr) do
    Repo.insert(%ScheduledReport{
      report_type: report_type,
      recipient_email: recipient_email,
      cron_expression: cron_expr,
      active: true,
      created_at: DateTime.utc_now()
    })
  end

  def dispatch_scheduled_reports do
    due = Repo.all(from r in ScheduledReport, where: r.active == true)

    Enum.each(due, fn report ->
      if Crontab.CronExpression.Composer.compose(report.cron_expression) do
        generate_and_send(report)
      end
    end)
  end

  defp generate_and_send(%ScheduledReport{report_type: type, recipient_email: email}) do
    today = Date.utc_today()
    {from, to} = {Date.add(today, -30), today}

    {:ok, path} =
      case type do
        :revenue -> export_revenue_csv(from, to)
        :growth -> export_growth_pdf(from, to)
      end

    Mailer.send(%{
      to: email,
      subject: "Scheduled Report: #{type}",
      body: "Please find your scheduled report attached.",
      attachment: path
    })

    Logger.info("Scheduled #{type} report sent to #{email}")
  end

  def pause_scheduled_report(report_id) do
    Repo.get!(ScheduledReport, report_id)
    |> ScheduledReport.changeset(%{active: false})
    |> Repo.update()
  end
end
# VALIDATION: SMELL END
```
