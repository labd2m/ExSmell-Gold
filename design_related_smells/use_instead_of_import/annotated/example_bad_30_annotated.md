# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `MetricsDashboard` module, top-level directive
- **Affected function(s):** `build_dashboard/2`, `funnel_report/2`, `retention_report/2`
- **Short explanation:** `MetricsDashboard` calls `use AggregationHelpers` to obtain metric-grouping and time-bucketing utilities. The `__using__/1` macro of `AggregationHelpers` covertly injects an `import` of `TimeSeriesUtils` into the caller, making `bucket_by/3`, `fill_gaps/3`, and `rolling_average/2` available without any explicit import. Replacing `use AggregationHelpers` with `import AggregationHelpers` would keep all injected names visible to the reader of `MetricsDashboard`.

---

```elixir
defmodule TimeSeriesUtils do
  def bucket_by(events, :hour, key_fn) do
    Enum.group_by(events, fn e ->
      dt = key_fn.(e)
      %{year: dt.year, month: dt.month, day: dt.day, hour: dt.hour}
    end)
  end

  def bucket_by(events, :day, key_fn) do
    Enum.group_by(events, fn e ->
      dt = key_fn.(e)
      %{year: dt.year, month: dt.month, day: dt.day}
    end)
  end

  def fill_gaps(buckets, start_date, end_date) do
    all_days =
      Stream.iterate(start_date, &Date.add(&1, 1))
      |> Stream.take_while(&(Date.compare(&1, end_date) != :gt))
      |> Enum.map(fn d -> %{year: d.year, month: d.month, day: d.day} end)

    Enum.map(all_days, fn key ->
      {key, Map.get(buckets, key, [])}
    end)
  end

  def rolling_average(values, window) when length(values) >= window do
    values
    |> Enum.chunk_every(window, 1, :discard)
    |> Enum.map(fn chunk -> Enum.sum(chunk) / window end)
  end
  def rolling_average(values, _window), do: values
end

defmodule AggregationHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 injects `import TimeSeriesUtils`
      # VALIDATION: into MetricsDashboard. bucket_by/3, fill_gaps/3, and
      # VALIDATION: rolling_average/2 appear in MetricsDashboard without an explicit
      # VALIDATION: import statement. A maintainer reading MetricsDashboard cannot
      # VALIDATION: determine the origin of these helpers without inspecting
      # VALIDATION: AggregationHelpers. A plain `import AggregationHelpers` would keep
      # VALIDATION: the dependency surface clear and auditable.
      import TimeSeriesUtils
      # VALIDATION: SMELL END

      def sum_metric(records, field), do: Enum.sum(Enum.map(records, &Map.get(&1, field, 0)))

      def avg_metric([], _field), do: 0.0
      def avg_metric(records, field) do
        sum_metric(records, field) / length(records)
      end

      def top_by(records, field, n) do
        records
        |> Enum.sort_by(&Map.get(&1, field, 0), :desc)
        |> Enum.take(n)
      end

      def count_distinct(records, field) do
        records |> Enum.map(&Map.get(&1, field)) |> Enum.uniq() |> length()
      end
    end
  end
end

defmodule MetricsDashboard do
  use AggregationHelpers

  @rolling_window 7

  def build_dashboard(events, date_range) do
    {start_d, end_d} = date_range

    daily_buckets =
      events
      |> bucket_by(:day, & &1.occurred_at)
      |> fill_gaps(start_d, end_d)

    daily_counts  = Enum.map(daily_buckets, fn {_k, recs} -> length(recs) end)
    daily_revenue = Enum.map(daily_buckets, fn {_k, recs} -> sum_metric(recs, :revenue) end)

    %{
      total_events:    length(events),
      unique_users:    count_distinct(events, :user_id),
      total_revenue:   Enum.sum(daily_revenue),
      avg_daily:       avg_metric(events, :revenue),
      daily_counts:    daily_counts,
      daily_revenue:   daily_revenue,
      rolling_avg:     rolling_average(daily_counts, @rolling_window),
      top_users:       top_by(events, :revenue, 10),
      generated_at:    DateTime.utc_now()
    }
  end

  def funnel_report(events, stages) do
    Enum.map(stages, fn stage ->
      matching = Enum.filter(events, &(&1.type == stage))
      %{
        stage:   stage,
        count:   length(matching),
        revenue: sum_metric(matching, :revenue)
      }
    end)
  end

  def retention_report(cohorts, events) do
    Enum.map(cohorts, fn cohort ->
      cohort_events = Enum.filter(events, &(&1.cohort == cohort.id))
      daily         = bucket_by(cohort_events, :day, & &1.occurred_at)
      counts        = Enum.map(daily, fn {_k, recs} -> count_distinct(recs, :user_id) end)
      %{
        cohort_id:    cohort.id,
        cohort_size:  cohort.size,
        daily_active: counts,
        rolling_avg:  rolling_average(counts, @rolling_window),
        avg_daily:    if(counts == [], do: 0.0, else: Enum.sum(counts) / length(counts))
      }
    end)
  end

  def hourly_breakdown(events) do
    events
    |> bucket_by(:hour, & &1.occurred_at)
    |> Enum.map(fn {bucket, recs} ->
      %{
        bucket:  bucket,
        count:   length(recs),
        revenue: sum_metric(recs, :revenue),
        avg_rev: avg_metric(recs, :revenue)
      }
    end)
    |> Enum.sort_by(& {&1.bucket.hour}, :asc)
  end
end
```
