# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `metric_key/2` function
- **Affected function(s):** `metric_key/2`, `record/3`
- **Short explanation:** The function builds a metric key atom by concatenating a service name and metric name strings received at runtime from various callers across the application and then calls `String.to_atom/1`. Because service and metric names can be composed in arbitrary combinations, this creates a potentially unbounded set of atoms.

---

```elixir
defmodule Telemetry.MetricsCollector do
  @moduledoc """
  Collects application metrics from multiple services and periodically flushes
  them to the configured metrics backend (StatsD / Prometheus).
  """

  use GenServer

  require Logger

  alias Telemetry.{MetricsBackend, AggregationBuffer}

  @flush_interval_ms 10_000
  @max_buffer_size 10_000

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(String.t(), String.t(), number()) :: :ok
  def record(service, metric, value) do
    GenServer.cast(__MODULE__, {:record, service, metric, value})
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend, MetricsBackend.StatsD)
    schedule_flush()

    {:ok,
     %{
       buffer: %{},
       backend: backend,
       flush_count: 0,
       total_recorded: 0
     }}
  end

  @impl true
  def handle_cast({:record, service, metric, value}, state) do
    # VALIDATION: SMELL START - Dynamic atom creation
    # VALIDATION: This is a smell because `metric_key/2` calls
    # `String.to_atom/1` on a string composed from the `service` and `metric`
    # arguments that are passed freely by callers throughout the codebase.
    # Any new service name or metric name combination will produce a new atom.
    # As the system grows and more services emit metrics, the atom table grows
    # in an unbounded, uncontrolled way.
    key = metric_key(service, metric)
    # VALIDATION: SMELL END

    updated_buffer =
      if map_size(state.buffer) >= @max_buffer_size do
        Logger.warning("Metrics buffer full, dropping oldest entries")
        state.buffer |> Enum.take(@max_buffer_size - 1) |> Map.new()
      else
        state.buffer
      end

    new_buffer = Map.update(updated_buffer, key, [value], &[value | &1])

    {:noreply, %{state | buffer: new_buffer, total_recorded: state.total_recorded + 1}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush(state)
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush()
    do_flush(state)
  end

  defp do_flush(%{buffer: buffer, backend: backend, flush_count: flush_count} = state) do
    if map_size(buffer) > 0 do
      aggregated = aggregate(buffer)

      case MetricsBackend.publish(backend, aggregated) do
        :ok ->
          Logger.debug("Metrics flushed", count: map_size(aggregated))

        {:error, reason} ->
          Logger.error("Metrics flush failed", reason: inspect(reason))
      end
    end

    {:reply, :ok, %{state | buffer: %{}, flush_count: flush_count + 1}}
  end

  defp aggregate(buffer) do
    Map.new(buffer, fn {key, values} ->
      stats = %{
        count: length(values),
        sum: Enum.sum(values),
        min: Enum.min(values),
        max: Enum.max(values),
        avg: Enum.sum(values) / max(length(values), 1)
      }

      {key, stats}
    end)
  end

  defp metric_key(service, metric) when is_binary(service) and is_binary(metric) do
    "#{service}.#{metric}" |> String.to_atom()
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end
```
