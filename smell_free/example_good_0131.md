```elixir
defmodule MyApp.Reporting.DailySummaryJob do
  @moduledoc """
  An Oban worker that aggregates the previous day's order and revenue
  metrics, persists the summary record, and emails the report to all
  admin users. Executed once per day at 06:00 UTC via a cron schedule
  defined in `config/config.exs`.

  The job is idempotent: re-enqueuing it for the same UTC date will
  simply produce a duplicate summary record with the same date key,
  which is deduplicated by a unique index on `daily_summaries.date`.
  """

  use Oban.Worker, queue: :reporting, max_attempts: 3

  require Logger

  alias MyApp.Repo
  alias MyApp.Reporting.{DailySummary, SummaryQuery}
  alias MyApp.Mailer
  alias MyApp.Accounts

  import Ecto.Query, warn: false

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    report_date = parse_report_date(args)

    Logger.info("daily_summary_job_started", date: Date.to_iso8601(report_date))

    with {:ok, metrics} <- SummaryQuery.run(report_date),
         {:ok, _summary} <- persist_summary(report_date, metrics),
         :ok <- deliver_reports(report_date, metrics) do
      Logger.info("daily_summary_job_finished", date: Date.to_iso8601(report_date))
      :ok
    end
  end

  @spec parse_report_date(%{optional(String.t()) => term()}) :: Date.t()
  defp parse_report_date(%{"date" => iso_string}) when is_binary(iso_string) do
    Date.from_iso8601!(iso_string)
  end

  defp parse_report_date(_args) do
    Date.utc_today() |> Date.add(-1)
  end

  @spec persist_summary(Date.t(), map()) ::
          {:ok, DailySummary.t()} | {:error, Ecto.Changeset.t()}
  defp persist_summary(date, metrics) do
    %DailySummary{}
    |> DailySummary.changeset(%{
      date: date,
      total_orders: metrics.total_orders,
      completed_orders: metrics.completed_orders,
      cancelled_orders: metrics.cancelled_orders,
      gross_revenue_cents: metrics.gross_revenue_cents,
      net_revenue_cents: metrics.net_revenue_cents,
      new_customers: metrics.new_customers,
      average_order_cents: metrics.average_order_cents
    })
    |> Repo.insert(
      on_conflict: {:replace, [:total_orders, :completed_orders, :cancelled_orders,
                               :gross_revenue_cents, :net_revenue_cents,
                               :new_customers, :average_order_cents, :updated_at]},
      conflict_target: :date
    )
  end

  @spec deliver_reports(Date.t(), map()) :: :ok
  defp deliver_reports(date, metrics) do
    admins = Accounts.list_admins()

    Enum.each(admins, fn admin ->
      case Mailer.deliver_daily_summary(admin, date, metrics) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("daily_summary_email_failed",
            admin_id: admin.id,
            reason: inspect(reason)
          )
      end
    end)
  end
end
```
