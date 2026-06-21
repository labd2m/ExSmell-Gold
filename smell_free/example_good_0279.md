```elixir
defmodule MyApp.Reports.MetricAggregator do
  @moduledoc """
  Aggregates time-series metric data into configurable window summaries
  (hourly, daily, weekly). Each aggregation is computed from raw
  `metric_events` table records using a single grouped Ecto query per
  window, rather than pulling all rows into memory for processing.

  The module is stateless and intended to be called from report-generation
  jobs or on-demand API endpoints.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Metrics.MetricEvent

  @type window :: :hourly | :daily | :weekly
  @type metric_name :: String.t()

  @type bucket :: %{
          period_start: DateTime.t(),
          count: non_neg_integer(),
          sum: float(),
          min: float(),
          max: float(),
          avg: float()
        }

  @doc """
  Returns aggregated `metric_name` values bucketed into `window` periods
  between `from` and `to` (inclusive). Results are ordered chronologically.
  """
  @spec aggregate(metric_name(), window(), DateTime.t(), DateTime.t()) :: [bucket()]
  def aggregate(metric_name, window, %DateTime{} = from, %DateTime{} = to)
      when is_binary(metric_name) and window in [:hourly, :daily, :weekly] do
    trunc_fn = truncation_fragment(window)

    MetricEvent
    |> where([e], e.name == ^metric_name)
    |> where([e], e.recorded_at >= ^from and e.recorded_at <= ^to)
    |> group_by([e], fragment(^trunc_fn, e.recorded_at))
    |> order_by([e], asc: fragment(^trunc_fn, e.recorded_at))
    |> select([e], %{
      period_start: fragment(^trunc_fn, e.recorded_at),
      count: count(e.id),
      sum: sum(e.value),
      min: min(e.value),
      max: max(e.value),
      avg: avg(e.value)
    })
    |> Repo.all()
    |> Enum.map(&round_floats/1)
  end

  @doc """
  Returns the overall percentile distribution for `metric_name` in the
  given time range as a map of percentile labels to values.
  """
  @spec percentiles(metric_name(), DateTime.t(), DateTime.t()) :: map()
  def percentiles(metric_name, %DateTime{} = from, %DateTime{} = to)
      when is_binary(metric_name) do
    MetricEvent
    |> where([e], e.name == ^metric_name)
    |> where([e], e.recorded_at >= ^from and e.recorded_at <= ^to)
    |> select([e], %{
      p50: fragment("percentile_cont(0.50) WITHIN GROUP (ORDER BY ?)", e.value),
      p90: fragment("percentile_cont(0.90) WITHIN GROUP (ORDER BY ?)", e.value),
      p95: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", e.value),
      p99: fragment("percentile_cont(0.99) WITHIN GROUP (ORDER BY ?)", e.value)
    })
    |> Repo.one()
    |> case do
      nil -> %{p50: nil, p90: nil, p95: nil, p99: nil}
      result -> result
    end
  end

  @doc """
  Returns the top-N metric sources by total value in the given window.
  """
  @spec top_sources(metric_name(), DateTime.t(), DateTime.t(), pos_integer()) :: [map()]
  def top_sources(metric_name, from, to, limit \\ 10)
      when is_binary(metric_name) and is_integer(limit) and limit > 0 do
    MetricEvent
    |> where([e], e.name == ^metric_name)
    |> where([e], e.recorded_at >= ^from and e.recorded_at <= ^to)
    |> group_by([e], e.source)
    |> order_by([e], desc: sum(e.value))
    |> limit(^limit)
    |> select([e], %{source: e.source, total: sum(e.value), count: count(e.id)})
    |> Repo.all()
  end

  @spec truncation_fragment(window()) :: String.t()
  defp truncation_fragment(:hourly), do: "date_trunc('hour', ?)"
  defp truncation_fragment(:daily), do: "date_trunc('day', ?)"
  defp truncation_fragment(:weekly), do: "date_trunc('week', ?)"

  @spec round_floats(bucket()) :: bucket()
  defp round_floats(bucket) do
    Map.update!(bucket, :avg, &Float.round(&1 || 0.0, 4))
  end
end
```
