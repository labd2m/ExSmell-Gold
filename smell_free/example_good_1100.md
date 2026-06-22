```elixir
defmodule Telemetry.MetricBuffer do
  @moduledoc """
  A GenServer that accumulates telemetry events in memory and flushes them
  to a configured reporter on a fixed interval.

  Events are stored as a list of tagged measurements. The flush interval and
  reporter module are supplied at startup via options, making the buffer
  reusable across different observability backends.
  """

  use GenServer

  @type measurement :: %{name: [atom()], value: number(), metadata: map()}
  @type options :: [reporter: module(), flush_interval_ms: pos_integer()]

  defstruct [:reporter, :flush_interval_ms, events: []]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Starts the buffer process linked to a supervisor."
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueues a single measurement for deferred flushing."
  @spec record(measurement()) :: :ok
  def record(%{name: name, value: value, metadata: metadata} = _measurement)
      when is_list(name) and is_number(value) and is_map(metadata) do
    GenServer.cast(__MODULE__, {:record, %{name: name, value: value, metadata: metadata}})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    reporter = Keyword.fetch!(opts, :reporter)
    interval = Keyword.get(opts, :flush_interval_ms, 5_000)
    schedule_flush(interval)
    {:ok, %__MODULE__{reporter: reporter, flush_interval_ms: interval}}
  end

  @impl GenServer
  def handle_cast({:record, measurement}, state) do
    {:noreply, %{state | events: [measurement | state.events]}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    flush_events(state.reporter, state.events)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | events: []}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)

  defp flush_events(_reporter, []), do: :ok
  defp flush_events(reporter, events), do: reporter.report(Enum.reverse(events))
end

defmodule Telemetry.Reporters.LogReporter do
  @moduledoc "Writes flushed telemetry events to the application logger."

  require Logger

  @doc "Receives a list of measurements and logs each one at debug level."
  @spec report([Telemetry.MetricBuffer.measurement()]) :: :ok
  def report(events) when is_list(events) do
    Enum.each(events, fn %{name: name, value: value, metadata: meta} ->
      Logger.debug("metric", name: inspect(name), value: value, metadata: meta)
    end)
  end
end
```
