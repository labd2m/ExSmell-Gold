```elixir
defmodule Telemetry.MetricsAggregator do
  @moduledoc """
  In-process metrics aggregator for lightweight operational observability.

  Collects counter, gauge, and histogram measurements emitted via the
  `:telemetry` library. Aggregates are computed in rolling 60-second windows
  and can be snapshotted at any time for export to external monitoring systems.
  """

  use GenServer

  require Logger

  @flush_interval_ms 60_000
  @histogram_buckets [5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]

  @type metric_name :: [atom()]
  @type snapshot :: %{
          counters: %{metric_name() => non_neg_integer()},
          gauges: %{metric_name() => number()},
          histograms: %{metric_name() => %{buckets: map(), count: non_neg_integer(), sum: number()}}
        }

  @doc """
  Starts the metrics aggregator as a named linked process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a snapshot of all current aggregated metric values.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Attaches the aggregator to a list of telemetry event names.

  All attached events will be captured and aggregated by metric type.
  """
  @spec attach_events([[atom()]]) :: :ok
  def attach_events(event_names) when is_list(event_names) do
    Enum.each(event_names, fn event_name ->
      :telemetry.attach(
        handler_id(event_name),
        event_name,
        &__MODULE__.handle_telemetry_event/4,
        nil
      )
    end)
  end

  @doc false
  def handle_telemetry_event(event_name, measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:record, event_name, measurements})
  end

  @impl GenServer
  def init(_opts) do
    schedule_flush()

    {:ok,
     %{
       counters: %{},
       gauges: %{},
       histograms: %{}
     }}
  end

  @impl GenServer
  def handle_cast({:record, event_name, %{count: delta}}, state) do
    updated = Map.update(state.counters, event_name, delta, &(&1 + delta))
    {:noreply, %{state | counters: updated}}
  end

  def handle_cast({:record, event_name, %{value: value}}, state) do
    updated = Map.put(state.gauges, event_name, value)
    {:noreply, %{state | gauges: updated}}
  end

  def handle_cast({:record, event_name, %{duration: duration}}, state) do
    updated = Map.update(state.histograms, event_name, new_histogram(duration), fn h ->
      update_histogram(h, duration)
    end)
    {:noreply, %{state | histograms: updated}}
  end

  def handle_cast({:record, _event_name, _measurements}, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    Logger.debug("[MetricsAggregator] Rolling window flush",
      counter_count: map_size(state.counters),
      histogram_count: map_size(state.histograms)
    )

    schedule_flush()
    {:noreply, %{state | counters: %{}, gauges: %{}, histograms: %{}}}
  end

  defp new_histogram(value) do
    buckets = Map.new(@histogram_buckets, fn b -> {b, if(value <= b, do: 1, else: 0)} end)
    %{buckets: buckets, count: 1, sum: value}
  end

  defp update_histogram(%{buckets: buckets, count: count, sum: sum}, value) do
    updated_buckets = Map.new(buckets, fn {b, n} -> {b, if(value <= b, do: n + 1, else: n)} end)
    %{buckets: updated_buckets, count: count + 1, sum: sum + value}
  end

  defp handler_id(event_name) do
    "metrics_aggregator_#{Enum.join(event_name, "_")}"
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end
```
