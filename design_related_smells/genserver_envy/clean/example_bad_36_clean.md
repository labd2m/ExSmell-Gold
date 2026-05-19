```elixir
defmodule MyApp.MetricsPipelineTask do
  @moduledoc """
  Aggregates application metrics in rolling time windows and flushes
  summarised data to the time-series store at configurable intervals.
  """

  alias MyApp.{TimeSeriesStore, AlertService}
  alias MyApp.Metrics.{DataPoint, WindowSummary}

  @flush_interval_ms 60_000
  @window_size_seconds 60
  @alert_on_spike_factor 3.0

  def start_pipeline(config) do
    Task.start_link(fn ->
      state = %{
        config: config,
        windows: %{},
        baselines: %{},
        flush_seq: 0
      }

      schedule_flush()
      pipeline_loop(state)
    end)
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp pipeline_loop(state) do
    receive do
      {:ingest, _from, %DataPoint{} = dp} ->
        bucket = time_bucket(dp.timestamp)
        window_key = {dp.metric, dp.tags, bucket}

        current =
          Map.get(state.windows, window_key, %{
            sum: 0,
            count: 0,
            min: nil,
            max: nil,
            samples: []
          })

        updated = %{
          current
          | sum: current.sum + dp.value,
            count: current.count + 1,
            min: min_or(current.min, dp.value),
            max: max_or(current.max, dp.value),
            samples: [dp.value | Enum.take(current.samples, 99)]
        }

        new_windows = Map.put(state.windows, window_key, updated)

        new_state =
          check_anomaly(%{state | windows: new_windows}, dp.metric, dp.tags, dp.value)

        pipeline_loop(new_state)

      {:query, from, metric, tags, since} ->
        since_bucket = time_bucket(since)

        matching =
          state.windows
          |> Enum.filter(fn {{m, t, b}, _} ->
            m == metric and t == tags and b >= since_bucket
          end)
          |> Enum.map(fn {{_, _, bucket}, window} ->
            %WindowSummary{
              metric: metric,
              tags: tags,
              bucket: bucket,
              avg: window.sum / max(window.count, 1),
              min: window.min,
              max: window.max,
              count: window.count
            }
          end)
          |> Enum.sort_by(& &1.bucket)

        send(from, {:ok, matching})
        pipeline_loop(state)

      :flush ->
        now_bucket = time_bucket(DateTime.utc_now())

        {to_flush, retain} =
          Enum.split_with(state.windows, fn {{_m, _t, bucket}, _} ->
            bucket < now_bucket
          end)

        summaries =
          Enum.map(to_flush, fn {{metric, tags, bucket}, window} ->
            %WindowSummary{
              metric: metric,
              tags: tags,
              bucket: bucket,
              avg: window.sum / max(window.count, 1),
              min: window.min,
              max: window.max,
              count: window.count
            }
          end)

        TimeSeriesStore.bulk_insert(summaries)

        new_baselines =
          Enum.reduce(summaries, state.baselines, fn s, acc ->
            key = {s.metric, s.tags}
            Map.update(acc, key, s.avg, fn prev -> prev * 0.9 + s.avg * 0.1 end)
          end)

        schedule_flush()

        pipeline_loop(%{
          state
          | windows: Map.new(retain),
            baselines: new_baselines,
            flush_seq: state.flush_seq + 1
        })

      {:get_stats, from} ->
        stats = %{
          active_windows: map_size(state.windows),
          tracked_metrics: state.windows |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length(),
          flush_seq: state.flush_seq
        }
        send(from, {:ok, stats})
        pipeline_loop(state)

      :stop ->
        :ok
    end
  end

  defp check_anomaly(state, metric, tags, value) do
    baseline = Map.get(state.baselines, {metric, tags})

    if baseline && baseline > 0 && value > baseline * @alert_on_spike_factor do
      AlertService.notify(:metric_spike, %{metric: metric, value: value, baseline: baseline})
    end

    state
  end

  defp time_bucket(dt) do
    dt |> DateTime.to_unix() |> div(@window_size_seconds)
  end

  defp min_or(nil, v), do: v
  defp min_or(current, v), do: min(current, v)

  defp max_or(nil, v), do: v
  defp max_or(current, v), do: max(current, v)

  def ingest(pid, data_point) do
    send(pid, {:ingest, self(), data_point})
  end

  def query(pid, metric, tags, since) do
    send(pid, {:query, self(), metric, tags, since})

    receive do
      {:ok, summaries} -> {:ok, summaries}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def get_stats(pid) do
    send(pid, {:get_stats, self()})

    receive do
      {:ok, stats} -> {:ok, stats}
    after
      3_000 -> {:error, :timeout}
    end
  end
end
```
