```elixir
defmodule Telemetry.MetricsAggregator do
  @moduledoc """
  GenServer that subscribes to application telemetry events and
  maintains rolling in-memory counters and histograms per metric key.

  Aggregated values can be polled via `snapshot/0` at any time,
  making this a lightweight alternative to external metrics pipelines
  during development and testing.
  """

  use GenServer

  @type metric_key :: String.t()
  @type histogram :: %{count: non_neg_integer(), sum: number(), min: number(), max: number()}
  @type counter :: non_neg_integer()
  @type snapshot :: %{counters: %{metric_key() => counter()}, histograms: %{metric_key() => histogram()}}

  @default_events [
    [:my_app, :request, :stop],
    [:my_app, :db, :query],
    [:my_app, :cache, :hit],
    [:my_app, :cache, :miss]
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns a point-in-time snapshot of all counters and histograms.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Resets all counters and histograms to zero.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @impl GenServer
  def init(opts) do
    events = Keyword.get(opts, :events, @default_events)
    Enum.each(events, &attach_handler/1)

    state = %{counters: %{}, histograms: %{}}
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_cast(:reset, _state) do
    {:noreply, %{counters: %{}, histograms: %{}}}
  end

  @impl GenServer
  def handle_info({:telemetry_event, event_name, measurements, _metadata}, state) do
    key = Enum.join(event_name, ".")

    updated =
      case Map.get(measurements, :duration) do
        nil -> increment_counter(state, key)
        duration -> record_histogram(state, key, duration)
      end

    {:noreply, updated}
  end

  @spec increment_counter(map(), metric_key()) :: map()
  defp increment_counter(state, key) do
    updated = Map.update(state.counters, key, 1, &(&1 + 1))
    %{state | counters: updated}
  end

  @spec record_histogram(map(), metric_key(), number()) :: map()
  defp record_histogram(state, key, value) do
    updated =
      Map.update(state.histograms, key, initial_histogram(value), fn hist ->
        %{
          count: hist.count + 1,
          sum: hist.sum + value,
          min: min(hist.min, value),
          max: max(hist.max, value)
        }
      end)

    %{state | histograms: updated}
  end

  @spec initial_histogram(number()) :: histogram()
  defp initial_histogram(value) do
    %{count: 1, sum: value, min: value, max: value}
  end

  @spec attach_handler([atom()]) :: :ok
  defp attach_handler(event_name) do
    :telemetry.attach(
      handler_id(event_name),
      event_name,
      &handle_event/4,
      nil
    )
  end

  defp handle_event(event_name, measurements, metadata, _config) do
    send(__MODULE__, {:telemetry_event, event_name, measurements, metadata})
  end

  @spec handler_id([atom()]) :: String.t()
  defp handler_id(event_name) do
    "metrics_aggregator." <> Enum.join(event_name, ".")
  end
end
```
