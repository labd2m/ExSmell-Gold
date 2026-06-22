```elixir
defmodule MyApp.Reports.ScheduledReportRunner do
  @moduledoc """
  A GenServer that maintains a schedule of recurring reports and triggers
  generation when each report's next-run time is reached. Report
  schedules are loaded from the database at startup and refreshed when
  a schedule changes. Each report runs in a supervised Task so that a
  slow or failing report does not block the scheduler or other reports.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Reports.{ReportSchedule, ReportGenerator}

  import Ecto.Query, warn: false

  @check_interval_ms 60_000

  @type state :: %{schedules: [ReportSchedule.t()]}

  @doc "Starts the scheduled report runner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Forces an immediate reload of all report schedules from the database."
  @spec reload_schedules() :: :ok
  def reload_schedules, do: GenServer.cast(__MODULE__, :reload)

  @impl GenServer
  def init(_opts) do
    schedules = load_schedules()
    schedule_check()
    {:ok, %{schedules: schedules}}
  end

  @impl GenServer
  def handle_cast(:reload, state) do
    {:noreply, %{state | schedules: load_schedules()}}
  end

  @impl GenServer
  def handle_info(:check, state) do
    now = DateTime.utc_now()

    due =
      Enum.filter(state.schedules, fn schedule ->
        schedule.active and DateTime.compare(schedule.next_run_at, now) != :gt
      end)

    Enum.each(due, &run_report/1)

    updated_schedules =
      if due == [] do
        state.schedules
      else
        load_schedules()
      end

    schedule_check()
    {:noreply, %{state | schedules: updated_schedules}}
  end

  @spec run_report(ReportSchedule.t()) :: :ok
  defp run_report(schedule) do
    Logger.info("scheduled_report_triggered", report_id: schedule.report_id, name: schedule.name)

    Task.Supervisor.start_child(MyApp.Tasks.TaskSupervisor, fn ->
      case ReportGenerator.generate(schedule.report_id, schedule.parameters) do
        {:ok, _result} ->
          advance_schedule(schedule)
          Logger.info("scheduled_report_completed", report_id: schedule.report_id)

        {:error, reason} ->
          Logger.error("scheduled_report_failed",
            report_id: schedule.report_id,
            reason: inspect(reason)
          )
      end
    end)

    :ok
  end

  @spec advance_schedule(ReportSchedule.t()) :: :ok
  defp advance_schedule(schedule) do
    next = compute_next_run(schedule.cron_expression)

    schedule
    |> ReportSchedule.advance_changeset(%{last_run_at: DateTime.utc_now(), next_run_at: next})
    |> Repo.update()

    :ok
  end

  @spec compute_next_run(String.t()) :: DateTime.t()
  defp compute_next_run(cron_expression) do
    Crontab.CronExpression.Parser.parse!(cron_expression)
    |> Crontab.Scheduler.get_next_run_dates(DateTime.utc_now())
    |> Enum.at(0)
  rescue
    _ -> DateTime.add(DateTime.utc_now(), 3_600, :second)
  end

  @spec load_schedules() :: [ReportSchedule.t()]
  defp load_schedules do
    ReportSchedule
    |> where([s], s.active == true)
    |> Repo.all()
  end

  @spec schedule_check() :: reference()
  defp schedule_check, do: Process.send_after(self(), :check, @check_interval_ms)
end
```
