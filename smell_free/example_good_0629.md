```elixir
defmodule Reporting.ScheduledReporter do
  @moduledoc """
  Generates and delivers scheduled reports on a configurable cron-like
  schedule. Report definitions specify the report module, recipient list,
  delivery channel, and schedule expression. The reporter evaluates which
  definitions are due on each tick and delegates generation and delivery
  to the appropriate modules without coupling them together.
  """

  use GenServer

  require Logger

  alias Scheduling.CronParser
  alias Reports.PDFExporter
  alias Notifications.Dispatcher, as: Notify

  @type recipient :: String.t()
  @type report_def :: %{
          id: String.t(),
          module: module(),
          params: map(),
          schedule: String.t(),
          recipients: [recipient()],
          channel: :email | :slack
        }

  @tick_interval_ms :timer.minutes(1)

  @doc "Starts the scheduled reporter."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a new report definition. Replaces any existing definition with the same ID."
  @spec register(report_def()) :: :ok
  def register(%{id: _, module: _, schedule: _, recipients: _, channel: _} = def_map) do
    GenServer.call(__MODULE__, {:register, def_map})
  end

  @doc "Removes a report definition by its ID."
  @spec deregister(String.t()) :: :ok
  def deregister(report_id) when is_binary(report_id) do
    GenServer.cast(__MODULE__, {:deregister, report_id})
  end

  @doc "Returns all registered report definitions."
  @spec registered_reports() :: [report_def()]
  def registered_reports, do: GenServer.call(__MODULE__, :registered_reports)

  @impl GenServer
  def init(opts) do
    defs = Keyword.get(opts, :reports, [])
    tick = Keyword.get(opts, :tick_interval_ms, @tick_interval_ms)
    Process.send_after(self(), :tick, tick)
    {:ok, %{definitions: Map.new(defs, &{&1.id, &1}), tick_interval: tick}}
  end

  @impl GenServer
  def handle_call({:register, def_map}, _from, state) do
    {:reply, :ok, put_in(state, [:definitions, def_map.id], def_map)}
  end

  def handle_call(:registered_reports, _from, state) do
    {:reply, Map.values(state.definitions), state}
  end

  @impl GenServer
  def handle_cast({:deregister, report_id}, state) do
    {:noreply, update_in(state, [:definitions], &Map.delete(&1, report_id))}
  end

  @impl GenServer
  def handle_info(:tick, %{tick_interval: tick} = state) do
    now = DateTime.utc_now()
    due = Enum.filter(Map.values(state.definitions), &due_now?(&1, now))
    Enum.each(due, &dispatch_report/1)
    Process.send_after(self(), :tick, tick)
    {:noreply, state}
  end

  defp due_now?(%{schedule: schedule}, now) do
    case CronParser.parse(schedule) do
      {:ok, parsed} ->
        minute_start = %{now | second: 0, microsecond: {0, 0}}
        prev = DateTime.add(minute_start, -60, :second)

        case CronParser.next_after(parsed, prev) do
          {:ok, next} -> DateTime.diff(next, minute_start, :second) == 0
          _ -> false
        end

      _ ->
        false
    end
  end

  defp dispatch_report(%{id: id, module: mod, params: params, recipients: recipients, channel: channel}) do
    Logger.info("[ScheduledReporter] Generating report #{id}")

    case PDFExporter.export(mod, params) do
      {:ok, %{name: filename, bytes: _bytes}} ->
        Enum.each(recipients, fn recipient ->
          Notify.dispatch(%{
            type: :report_ready,
            recipient_id: recipient,
            payload: %{report_id: id, filename: filename, channel: channel}
          })
        end)

        Logger.info("[ScheduledReporter] Delivered report #{id} to #{length(recipients)} recipient(s)")

      {:error, reason} ->
        Logger.error("[ScheduledReporter] Report #{id} failed: #{inspect(reason)}")
    end
  end
end
```
