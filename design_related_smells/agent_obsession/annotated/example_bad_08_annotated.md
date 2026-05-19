# Annotated Example 08 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `MetricsCollector`, `AlertEvaluator`, `DashboardAggregator`, and `MetricsExporter` all interact directly with the Agent PID
- **Affected functions:** `MetricsCollector.record/3`, `AlertEvaluator.evaluate/1`, `DashboardAggregator.build_panel/2`, `MetricsExporter.export_csv/1`
- **Short explanation:** A shared metrics store is backed by an Agent, but four unrelated modules all call `Agent.get/2` and `Agent.update/2` directly. Each module accesses or manipulates the shared state without going through any encapsulating interface.

---

```elixir
defmodule MetricsCollector do
  @moduledoc """
  Collects runtime metrics from application services.
  """

  def start do
    Agent.start_link(fn -> %{series: %{}, alerts: [], last_flush: DateTime.utc_now()} end)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because MetricsCollector calls Agent.update/2
  # directly to append a metric data point into the shared state. The state
  # structure is defined here but other modules will also write to the same
  # Agent without any coordination.
  def record(pid, metric_name, value) when is_float(value) or is_integer(value) do
    Agent.update(pid, fn state ->
      point = %{value: value, recorded_at: DateTime.utc_now()}
      new_series = Map.update(state.series, metric_name, [point], fn pts -> [point | pts] end)
      %{state | series: new_series}
    end)
    :ok
  end
  # VALIDATION: SMELL END

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because AlertEvaluator directly calls
  # Agent.get/2 to read metrics and Agent.update/2 to inject alert records
  # into the :alerts list, sharing the same Agent the collector uses without
  # going through any owned interface.
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
  # VALIDATION: SMELL END

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because DashboardAggregator directly calls
  # Agent.get/2 to read raw series data, coupling it to the exact Agent state
  # structure written by MetricsCollector without any encapsulation layer.
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
  # VALIDATION: SMELL END

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because MetricsExporter directly reads the
  # entire Agent state with Agent.get/2 and updates :last_flush directly,
  # bypassing any centralized API and assuming the full Agent state layout
  # created by the other three modules.
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
  # VALIDATION: SMELL END
end
```
