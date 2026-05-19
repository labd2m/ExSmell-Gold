```elixir
defmodule MetricsCollector do
  @moduledoc """
  Collects runtime metrics from application services.
  """

  def start do
    Agent.start_link(fn -> %{series: %{}, alerts: [], last_flush: DateTime.utc_now()} end)
  end

  def record(pid, metric_name, value) when is_float(value) or is_integer(value) do
    Agent.update(pid, fn state ->
      point = %{value: value, recorded_at: DateTime.utc_now()}
      new_series = Map.update(state.series, metric_name, [point], fn pts -> [point | pts] end)
      %{state | series: new_series}
    end)
    :ok
  end

  def latest(pid, metric_name) do
    Agent.get(pid, fn state ->
      state.series
      |> Map.get(metric_name, [])
      |> List.first()
    end)
  end
end

defmodule AlertEvaluator do
  @moduledoc """
  Evaluates metric thresholds and records alert events.
  """

  def evaluate(pid) do
    Agent.get_and_update(pid, fn state ->
      new_alerts =
        state.series
        |> Enum.flat_map(fn {metric, points} ->
          case List.first(points) do
            nil -> []
            %{value: v} when v > 90 ->
              [%{metric: metric, level: :critical, value: v, triggered_at: DateTime.utc_now()}]
            %{value: v} when v > 70 ->
              [%{metric: metric, level: :warning, value: v, triggered_at: DateTime.utc_now()}]
            _ -> []
          end
        end)

      all_alerts = new_alerts ++ state.alerts
      {new_alerts, %{state | alerts: all_alerts}}
    end)
  end

  def active_alerts(pid) do
    Agent.get(pid, fn state ->
      Enum.filter(state.alerts, fn a -> a.level == :critical end)
    end)
  end
end

defmodule DashboardAggregator do
  @moduledoc """
  Builds aggregated panels for a real-time metrics dashboard.
  """

  def build_panel(pid, metric_name) do
    series = Agent.get(pid, fn state ->
      Map.get(state.series, metric_name, [])
    end)

    values = Enum.map(series, & &1.value)
    count = length(values)

    if count == 0 do
      %{metric: metric_name, status: :no_data}
    else
      avg = Enum.sum(values) / count
      max_val = Enum.max(values)
      min_val = Enum.min(values)

      %{
        metric: metric_name,
        avg: Float.round(avg, 2),
        max: max_val,
        min: min_val,
        sample_count: count
      }
    end
  end

  def overview(pid) do
    Agent.get(pid, fn state ->
      Map.keys(state.series)
    end)
  end
end

defmodule MetricsExporter do
  @moduledoc """
  Exports collected metrics to external systems.
  """

  def export_csv(pid) do
    state = Agent.get(pid, fn s -> s end)

    rows =
      state.series
      |> Enum.flat_map(fn {metric, points} ->
        Enum.map(points, fn %{value: v, recorded_at: t} ->
          "#{metric},#{v},#{DateTime.to_iso8601(t)}"
        end)
      end)

    csv = Enum.join(["metric,value,recorded_at" | rows], "\n")

    Agent.update(pid, fn s -> %{s | last_flush: DateTime.utc_now()} end)

    {:ok, csv}
  end
end
```
