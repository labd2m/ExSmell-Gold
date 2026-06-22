```elixir
defmodule Reporting.ExportScheduler do
  @moduledoc """
  Schedules and dispatches recurring report generation jobs based on
  cron-style definitions. Each definition specifies the report module,
  target recipients, delivery channel, and schedule. The scheduler ticks
  every minute and compares each definition's schedule against the current
  time to determine which reports are due, then dispatches generation tasks
  to a supervised task pool without blocking the scheduling loop.
  """

  use GenServer

  require Logger

  @type schedule_def :: %{
          id: String.t(),
          report_module: module(),
          params: map(),
          recipients: [String.t()],
          channel: atom(),
          cron: String.t(),
          enabled: boolean()
        }

  @tick_interval_ms :timer.minutes(1)

  @doc "Starts the export scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a new schedule definition. Replaces any with the same ID."
  @spec register(schedule_def()) :: :ok
  def register(%{id: _, report_module: _, cron: _, recipients: _} = def_map) do
    GenServer.call(__MODULE__, {:register, def_map})
  end

  @doc "Disables a scheduled report by ID without removing it."
  @spec disable(String.t()) :: :ok | {:error, :not_found}
  def disable(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:disable, id})
  end

  @doc "Returns all registered schedule definitions."
  @spec schedules() :: [schedule_def()]
  def schedules, do: GenServer.call(__MODULE__, :schedules)

  @impl GenServer
  def init(opts) do
    defs = Keyword.get(opts, :definitions, [])
    supervisor = Keyword.get(opts, :task_supervisor, Reporting.TaskSupervisor)
    tick = Keyword.get(opts, :tick_interval_ms, @tick_interval_ms)
    Process.send_after(self(), :tick, tick)
    {:ok, %{definitions: Map.new(defs, &{&1.id, &1}), supervisor: supervisor, tick: tick}}
  end

  @impl GenServer
  def handle_call({:register, def_map}, _from, state) do
    {:reply, :ok, put_in(state, [:definitions, def_map.id], def_map)}
  end

  def handle_call({:disable, id}, _from, state) do
    case Map.get(state.definitions, id) do
      nil -> {:reply, {:error, :not_found}, state}
      def_map ->
        updated = Map.put(state.definitions, id, %{def_map | enabled: false})
        {:reply, :ok, %{state | definitions: updated}}
    end
  end

  def handle_call(:schedules, _from, state) do
    {:reply, Map.values(state.definitions), state}
  end

  @impl GenServer
  def handle_info(:tick, %{tick: tick} = state) do
    now = DateTime.utc_now()

    state.definitions
    |> Map.values()
    |> Enum.filter(fn d -> d.enabled and due_now?(d.cron, now) end)
    |> Enum.each(&dispatch_report(&1, state.supervisor))

    Process.send_after(self(), :tick, tick)
    {:noreply, state}
  end

  defp due_now?(cron_expr, now) do
    case Scheduling.CronParser.parse(cron_expr) do
      {:ok, parsed} ->
        one_minute_ago = DateTime.add(now, -60, :second)

        case Scheduling.CronParser.next_after(parsed, one_minute_ago) do
          {:ok, next} -> DateTime.diff(next, now, :second) |> abs() <= 30
          _ -> false
        end

      _ ->
        false
    end
  end

  defp dispatch_report(%{id: id, report_module: mod, params: params, recipients: recipients, channel: channel}, supervisor) do
    Logger.info("[ExportScheduler] Dispatching report #{id}")

    Task.Supervisor.start_child(supervisor, fn ->
      case Reporting.ScheduledReporter.generate_and_deliver(mod, params, recipients, channel) do
        :ok -> Logger.info("[ExportScheduler] Report #{id} delivered")
        {:error, reason} -> Logger.error("[ExportScheduler] Report #{id} failed: #{inspect(reason)}")
      end
    end)
  end
end
```
