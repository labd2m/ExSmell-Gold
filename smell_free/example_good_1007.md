```elixir
defmodule MyApp.Reporting.ExportScheduler do
  @moduledoc """
  Schedules recurring data exports via Oban cron entries. Each export
  definition specifies a name, format, recipient list, and cron
  expression. Definitions are loaded from the `export_schedules` table
  at startup and dynamically managed: adding or removing a schedule
  takes effect without a restart.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Reporting.{ExportSchedule, ExportJob}

  import Ecto.Query, warn: false

  @sync_interval_ms 5 * 60 * 1_000

  @doc "Starts the export scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Forces an immediate sync of schedules from the database."
  @spec sync() :: :ok
  def sync, do: GenServer.cast(__MODULE__, :sync)

  @impl GenServer
  def init(_opts) do
    do_sync([])
    schedule_sync()
    {:ok, %{active_names: []}}
  end

  @impl GenServer
  def handle_cast(:sync, state) do
    new_names = do_sync(state.active_names)
    {:noreply, %{state | active_names: new_names}}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    new_names = do_sync(state.active_names)
    schedule_sync()
    {:noreply, %{state | active_names: new_names}}
  end

  @spec do_sync([String.t()]) :: [String.t()]
  defp do_sync(current_names) do
    active = load_active_schedules()
    active_names = Enum.map(active, & &1.name)

    removed = current_names -- active_names
    added = active_names -- current_names

    Enum.each(removed, &remove_cron_entry/1)
    Enum.each(active, fn schedule ->
      if schedule.name in added, do: add_cron_entry(schedule)
    end)

    active_names
  end

  @spec load_active_schedules() :: [ExportSchedule.t()]
  defp load_active_schedules do
    ExportSchedule
    |> where([s], s.active == true)
    |> Repo.all()
  end

  @spec add_cron_entry(ExportSchedule.t()) :: :ok
  defp add_cron_entry(schedule) do
    cron_entry = %Oban.Cron.Entry{
      expression: schedule.cron_expression,
      worker: ExportJob,
      args: %{schedule_id: schedule.id}
    }

    case Oban.Cron.put_cron(cron_entry) do
      :ok ->
        Logger.info("export_schedule_activated", name: schedule.name)

      {:error, reason} ->
        Logger.error("export_schedule_activation_failed",
          name: schedule.name,
          reason: inspect(reason)
        )
    end

    :ok
  end

  @spec remove_cron_entry(String.t()) :: :ok
  defp remove_cron_entry(name) do
    Oban.Cron.delete_cron(name)
    Logger.info("export_schedule_deactivated", name: name)
    :ok
  end

  @spec schedule_sync() :: reference()
  defp schedule_sync, do: Process.send_after(self(), :sync, @sync_interval_ms)
end
```
