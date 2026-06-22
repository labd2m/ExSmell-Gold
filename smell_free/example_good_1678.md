```elixir
defmodule Telemetry.SensorAggregator do
  @moduledoc """
  Collects raw sensor readings into fixed time windows and emits
  statistical summaries (min, max, mean, p95) at window boundaries.
  Windows are keyed by sensor ID to support independent timelines.
  """

  use GenServer

  alias Telemetry.{SummaryStore, AlertEvaluator}

  @window_ms 60_000

  @type sensor_id :: String.t()
  @type reading :: %{sensor_id: sensor_id(), value: float(), unit: String.t(), timestamp: DateTime.t()}
  @type window_summary :: %{
          sensor_id: sensor_id(),
          count: non_neg_integer(),
          min: float(),
          max: float(),
          mean: float(),
          p95: float(),
          unit: String.t(),
          window_start: DateTime.t(),
          window_end: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(reading()) :: :ok
  def record(%{sensor_id: _} = reading) do
    GenServer.cast(__MODULE__, {:record, reading})
  end

  @spec current_window_stats(sensor_id()) :: {:ok, map()} | {:error, :no_data}
  def current_window_stats(sensor_id) when is_binary(sensor_id) do
    GenServer.call(__MODULE__, {:stats, sensor_id})
  end

  @impl GenServer
  def init(opts) do
    window_ms = Keyword.get(opts, :window_ms, @window_ms)
    schedule_flush(window_ms)
    {:ok, %{readings: %{}, window_ms: window_ms, window_start: DateTime.utc_now()}}
  end

  @impl GenServer
  def handle_cast({:record, reading}, state) do
    updated = Map.update(state.readings, reading.sensor_id, [reading], &[reading | &1])
    {:noreply, %{state | readings: updated}}
  end

  @impl GenServer
  def handle_call({:stats, sensor_id}, _from, state) do
    result = case Map.fetch(state.readings, sensor_id) do
      {:ok, readings} -> {:ok, compute_stats(sensor_id, readings, state.window_start)}
      :error -> {:error, :no_data}
    end
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:flush_window, state) do
    now = DateTime.utc_now()

    summaries =
      state.readings
      |> Enum.map(fn {sensor_id, readings} ->
        compute_summary(sensor_id, readings, state.window_start, now)
      end)

    Enum.each(summaries, fn summary ->
      SummaryStore.persist(summary)
      AlertEvaluator.check(summary)
    end)

    schedule_flush(state.window_ms)
    {:noreply, %{state | readings: %{}, window_start: now}}
  end

  @spec compute_summary(sensor_id(), [reading()], DateTime.t(), DateTime.t()) :: window_summary()
  defp compute_summary(sensor_id, readings, window_start, window_end) do
    stats = compute_stats(sensor_id, readings, window_start)
    Map.merge(stats, %{window_start: window_start, window_end: window_end})
  end

  @spec compute_stats(sensor_id(), [reading()], DateTime.t()) :: map()
  defp compute_stats(sensor_id, readings, window_start) do
    values = Enum.map(readings, & &1.value)
    unit = readings |> List.first() |> Map.get(:unit, "")
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      sensor_id: sensor_id,
      count: count,
      min: List.first(sorted),
      max: List.last(sorted),
      mean: Enum.sum(values) / count,
      p95: percentile(sorted, 0.95),
      unit: unit,
      window_start: window_start
    }
  end

  @spec percentile([float()], float()) :: float()
  defp percentile(sorted, p) when length(sorted) > 0 do
    index = min(round(p * length(sorted)) - 1, length(sorted) - 1)
    Enum.at(sorted, max(0, index))
  end

  defp percentile(_, _), do: 0.0

  @spec schedule_flush(pos_integer()) :: reference()
  defp schedule_flush(ms), do: Process.send_after(self(), :flush_window, ms)
end
```
