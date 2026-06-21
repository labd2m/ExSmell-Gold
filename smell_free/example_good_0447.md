```elixir
defmodule Analytics.TimeSeries do
  @moduledoc """
  Provides time-series query helpers for event-count and metric aggregations
  stored in PostgreSQL. Aggregations at hour and day granularity are served
  from materialized views refreshed on a schedule, while live minute-level
  data is queried from the raw events table. All public functions return
  normalised result lists with a uniform `{timestamp, value}` shape.
  """

  alias Analytics.{Repo}
  import Ecto.Query

  @type granularity :: :minute | :hour | :day
  @type series_point :: %{timestamp: DateTime.t(), value: number()}
  @type metric_name :: binary()

  @doc """
  Returns aggregated event counts for `event_type` between `from` and `until`
  at the specified `granularity`. Fills in zero-value buckets for periods with
  no activity so the result always has a continuous, gap-free series.
  """
  @spec event_counts(binary(), DateTime.t(), DateTime.t(), granularity()) :: [series_point()]
  def event_counts(event_type, %DateTime{} = from, %DateTime{} = until, granularity)
      when is_binary(event_type) and granularity in [:minute, :hour, :day] do
    raw = query_event_counts(event_type, from, until, granularity)
    buckets = generate_buckets(from, until, granularity)
    fill_gaps(buckets, raw)
  end

  @doc """
  Returns aggregated metric values (sum or average) for `metric_name` over
  the given time range. Useful for revenue, latency, and custom instrumentation.
  """
  @spec metric_series(metric_name(), DateTime.t(), DateTime.t(), granularity(), :sum | :avg) ::
          [series_point()]
  def metric_series(metric_name, from, until, granularity, agg \\ :sum)
      when is_binary(metric_name) and granularity in [:minute, :hour, :day] and agg in [:sum, :avg] do
    raw = query_metric_series(metric_name, from, until, granularity, agg)
    buckets = generate_buckets(from, until, granularity)
    fill_gaps(buckets, raw, 0.0)
  end

  @doc """
  Returns a retention cohort map: for each `cohort_period`, what percentage
  of users who first appeared in that period returned in each subsequent period.
  """
  @spec retention_cohorts(Date.t(), Date.t()) :: [%{cohort: Date.t(), periods: [map()]}]
  def retention_cohorts(%Date{} = from, %Date{} = until) do
    Repo.query!("""
      SELECT
        DATE_TRUNC('week', first_seen::timestamptz) AS cohort,
        DATE_TRUNC('week', seen_at::timestamptz) AS period,
        COUNT(DISTINCT user_id) AS retained_users
      FROM analytics.user_activity
      WHERE first_seen >= $1 AND first_seen <= $2
      GROUP BY 1, 2
      ORDER BY 1, 2
    """, [from, until])
    |> Map.get(:rows)
    |> build_cohort_table()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp query_event_counts(event_type, from, until, granularity) do
    trunc_fn = trunc_function(granularity)

    Repo.query!("""
      SELECT DATE_TRUNC(#{trunc_fn}, occurred_at) AS bucket, COUNT(*) AS count
      FROM analytics.events
      WHERE event_type = $1
        AND occurred_at >= $2
        AND occurred_at < $3
      GROUP BY 1
      ORDER BY 1
    """, [event_type, from, until])
    |> rows_to_series()
  end

  defp query_metric_series(metric_name, from, until, granularity, :sum) do
    Repo.query!("""
      SELECT DATE_TRUNC(#{trunc_function(granularity)}, recorded_at) AS bucket,
             SUM(value) AS value
      FROM analytics.metrics
      WHERE metric_name = $1 AND recorded_at >= $2 AND recorded_at < $3
      GROUP BY 1 ORDER BY 1
    """, [metric_name, from, until])
    |> rows_to_series()
  end

  defp query_metric_series(metric_name, from, until, granularity, :avg) do
    Repo.query!("""
      SELECT DATE_TRUNC(#{trunc_function(granularity)}, recorded_at) AS bucket,
             AVG(value) AS value
      FROM analytics.metrics
      WHERE metric_name = $1 AND recorded_at >= $2 AND recorded_at < $3
      GROUP BY 1 ORDER BY 1
    """, [metric_name, from, until])
    |> rows_to_series()
  end

  defp rows_to_series(%{rows: rows, columns: cols}) do
    col_idx = Enum.with_index(cols) |> Map.new(fn {c, i} -> {c, i} end)

    Enum.map(rows, fn row ->
      ts = Enum.at(row, col_idx["bucket"])
      val = Enum.at(row, col_idx["count"] || col_idx["value"]) || 0
      %{timestamp: ts, value: val}
    end)
  end

  defp generate_buckets(from, until, granularity) do
    step = granularity_step(granularity)
    Stream.iterate(truncate(from, granularity), &DateTime.add(&1, step, :second))
    |> Stream.take_while(&(DateTime.compare(&1, until) != :gt))
    |> Enum.to_list()
  end

  defp fill_gaps(buckets, raw, default \\ 0) do
    raw_map = Map.new(raw, &{&1.timestamp, &1.value})
    Enum.map(buckets, fn bucket ->
      %{timestamp: bucket, value: Map.get(raw_map, bucket, default)}
    end)
  end

  defp truncate(dt, :minute), do: %{dt | second: 0, microsecond: {0, 0}}
  defp truncate(dt, :hour), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}
  defp truncate(dt, :day), do: %{dt | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  defp granularity_step(:minute), do: 60
  defp granularity_step(:hour), do: 3_600
  defp granularity_step(:day), do: 86_400

  defp trunc_function(:minute), do: "'minute'"
  defp trunc_function(:hour), do: "'hour'"
  defp trunc_function(:day), do: "'day'"

  defp build_cohort_table([]), do: []

  defp build_cohort_table(rows) do
    rows
    |> Enum.group_by(fn [cohort | _] -> cohort end)
    |> Enum.map(fn {cohort, cohort_rows} ->
      periods = Enum.map(cohort_rows, fn [_cohort, period, count] ->
        %{period: period, retained_users: count}
      end)
      %{cohort: cohort, periods: periods}
    end)
    |> Enum.sort_by(& &1.cohort, Date)
  end
end
```
