# Annotated Bad Example 44

- **Smell name:** GenServer Envy
- **Expected smell location:** `ReportAggregator` module — `Agent`-based process
- **Affected functions:** `build_summary_report/1`, `export_csv/1`, `detect_anomalies/2`
- **Short explanation:** The `Agent` legitimately stores accumulated metric data, but `build_summary_report/1`, `export_csv/1`, and `detect_anomalies/2` run large isolated computations entirely within `Agent.get` callbacks. These calculations serve only the calling process and should be plain functions operating on data fetched once — not isolated tasks run inside the Agent's serialized callback queue.

```elixir
defmodule ReportAggregator do
  @moduledoc """
  Aggregates time-series metrics for reporting dashboards.
  Receives raw event data from multiple producers and stores
  rolling windows of metrics for analysis and export.
  """

  use Agent

  require Logger

  @type metric_event :: %{
          timestamp: DateTime.t(),
          source: String.t(),
          metric: String.t(),
          value: float(),
          tags: map()
        }

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          events: [],
          sources: MapSet.new(),
          last_flush: DateTime.utc_now()
        }
      end,
      name: __MODULE__
    )
  end

  @doc "Records a new metric event into the aggregator."
  def record_event(%{source: source} = event) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | events: [event | state.events],
          sources: MapSet.put(state.sources, source)
      }
    end)
  end

  @doc "Returns raw events for a given source."
  def get_events_for_source(source) do
    Agent.get(__MODULE__, fn state ->
      Enum.filter(state.events, &(&1.source == source))
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because build_summary_report/1, export_csv/1,
  # and detect_anomalies/2 perform heavy, isolated computations inside
  # Agent.get/2 callbacks. The results are only used by the calling process
  # and have no relevance to any shared state. Running CPU-intensive logic
  # inside the Agent's serialized callback queue blocks other processes from
  # accessing the Agent, and this pattern belongs in a GenServer or plain module.

  @doc "Builds a statistical summary for a given metric — isolated computation."
  def build_summary_report(metric_name) do
    Agent.get(__MODULE__, fn state ->
      values =
        state.events
        |> Enum.filter(&(&1.metric == metric_name))
        |> Enum.map(& &1.value)

      if Enum.empty?(values) do
        {:error, :no_data}
      else
        sorted = Enum.sort(values)
        count = length(sorted)
        sum = Enum.sum(sorted)
        mean = sum / count
        min = List.first(sorted)
        max = List.last(sorted)

        median =
          if rem(count, 2) == 0 do
            mid = div(count, 2)
            (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
          else
            Enum.at(sorted, div(count, 2))
          end

        variance =
          sorted
          |> Enum.map(fn v -> :math.pow(v - mean, 2) end)
          |> Enum.sum()
          |> then(&(&1 / count))

        stddev = :math.sqrt(variance)

        {:ok,
         %{
           metric: metric_name,
           count: count,
           sum: Float.round(sum, 4),
           mean: Float.round(mean, 4),
           median: Float.round(median, 4),
           min: min,
           max: max,
           stddev: Float.round(stddev, 4)
         }}
      end
    end)
  end

  @doc "Produces a CSV export of all stored events — isolated task."
  def export_csv(source \\ nil) do
    Agent.get(__MODULE__, fn state ->
      events =
        if source do
          Enum.filter(state.events, &(&1.source == source))
        else
          state.events
        end

      header = "timestamp,source,metric,value\n"

      rows =
        events
        |> Enum.sort_by(& &1.timestamp, DateTime)
        |> Enum.map(fn e ->
          "#{DateTime.to_iso8601(e.timestamp)},#{e.source},#{e.metric},#{e.value}\n"
        end)
        |> Enum.join()

      header <> rows
    end)
  end

  @doc "Detects metrics whose latest value deviates beyond a given z-score — isolated task."
  def detect_anomalies(metric_name, z_threshold \\ 2.5) do
    Agent.get(__MODULE__, fn state ->
      values =
        state.events
        |> Enum.filter(&(&1.metric == metric_name))
        |> Enum.sort_by(& &1.timestamp, DateTime)
        |> Enum.map(& &1.value)

      if length(values) < 5 do
        {:error, :insufficient_data}
      else
        mean = Enum.sum(values) / length(values)

        variance =
          values
          |> Enum.map(fn v -> :math.pow(v - mean, 2) end)
          |> Enum.sum()
          |> then(&(&1 / length(values)))

        stddev = :math.sqrt(variance)

        anomalies =
          values
          |> Enum.with_index()
          |> Enum.filter(fn {v, _i} ->
            stddev > 0 and abs((v - mean) / stddev) > z_threshold
          end)
          |> Enum.map(fn {v, i} -> %{index: i, value: v} end)

        {:ok, %{metric: metric_name, anomalies: anomalies, stddev: Float.round(stddev, 4)}}
      end
    end)
  end

  # VALIDATION: SMELL END

  @doc "Flushes all stored events and resets state."
  def flush do
    Agent.update(__MODULE__, fn state ->
      %{state | events: [], last_flush: DateTime.utc_now()}
    end)
  end
end
```
