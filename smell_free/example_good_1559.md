```elixir
defmodule Telemetry.Metrics.Aggregator do
  @moduledoc """
  GenServer that accumulates and periodically flushes metric data
  to a configured backend sink.

  Metrics are buffered in memory and exported on a configurable interval
  to reduce sink write pressure in high-throughput environments.
  """

  use GenServer, restart: :permanent

  alias Telemetry.Metrics.{Counter, Gauge, Histogram}
  alias Telemetry.Sinks.BackendSink

  @default_flush_interval_ms 10_000

  @type metric_entry :: Counter.t() | Gauge.t() | Histogram.t()

  @type state :: %{
          buffer: [metric_entry()],
          flush_interval: pos_integer(),
          sink: module()
        }

  @doc """
  Starts the aggregator under a supervisor with the given sink and flush interval.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a metric entry into the aggregator buffer.
  """
  @spec record(metric_entry()) :: :ok
  def record(metric) do
    GenServer.cast(__MODULE__, {:record, metric})
  end

  @doc """
  Forces an immediate buffer flush to the configured sink.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    flush_interval = Keyword.get(opts, :flush_interval, @default_flush_interval_ms)
    sink = Keyword.fetch!(opts, :sink)

    schedule_flush(flush_interval)

    {:ok, %{buffer: [], flush_interval: flush_interval, sink: sink}}
  end

  @impl GenServer
  def handle_cast({:record, metric}, state) do
    {:noreply, %{state | buffer: [metric | state.buffer]}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    new_state = do_flush(state)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    schedule_flush(state.flush_interval)
    {:noreply, do_flush(state)}
  end

  defp do_flush(%{buffer: []} = state), do: state

  defp do_flush(%{buffer: buffer, sink: sink} = state) do
    aggregated = aggregate_buffer(buffer)

    case sink.export(aggregated) do
      :ok -> %{state | buffer: []}
      {:error, _reason} -> state
    end
  end

  defp aggregate_buffer(entries) do
    entries
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, grouped} -> merge_entries(name, grouped) end)
  end

  defp merge_entries(name, [%Counter{} | _] = entries) do
    total = Enum.reduce(entries, 0, fn e, acc -> acc + e.value end)
    %Counter{name: name, value: total}
  end

  defp merge_entries(name, [%Gauge{} | _] = entries) do
    latest = List.last(entries)
    %Gauge{name: name, value: latest.value, timestamp: latest.timestamp}
  end

  defp merge_entries(name, [%Histogram{} | _] = entries) do
    all_observations = Enum.flat_map(entries, & &1.observations)
    %Histogram{name: name, observations: all_observations}
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :scheduled_flush, interval)
  end
end
```
