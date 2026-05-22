# example_bad_10_annotated.md

## Metadata

- **Smell Name:** "Use" instead of "import"
- **Expected Smell Location:** `Analytics.EventAggregator` module, `use Analytics.AggregationHelpers` directive
- **Affected Function(s):** Module-level directive (affects the entire `Analytics.EventAggregator` module)
- **Short Explanation:** `Analytics.EventAggregator` uses `use Analytics.AggregationHelpers` solely to access event-grouping and counting helpers. The `__using__/1` macro additionally injects `import Analytics.StatUtils` into the caller, making statistical functions available in `EventAggregator` without any explicit declaration. Since the module only needs the aggregation helpers, `import Analytics.AggregationHelpers` would be the correct and transparent alternative.

## Code

```elixir
defmodule Analytics.StatUtils do
  @moduledoc """
  Statistical computation utilities shared across the analytics platform.
  """

  def variance(list) when length(list) < 2, do: 0.0
  def variance(list) do
    n    = length(list)
    avg  = Enum.sum(list) / n
    sum_sq = Enum.reduce(list, 0.0, fn x, acc -> acc + (x - avg) ** 2 end)
    sum_sq / n
  end

  def std_dev(list), do: list |> variance() |> :math.sqrt()

  def percentile([], _), do: nil
  def percentile(list, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(list)
    idx    = (p / 100 * (length(sorted) - 1)) |> round()
    Enum.at(sorted, idx)
  end

  def z_score(value, list) do
    avg = Enum.sum(list) / length(list)
    sd  = std_dev(list)
    if sd == 0.0, do: 0.0, else: (value - avg) / sd
  end
end

defmodule Analytics.AggregationHelpers do
  @moduledoc """
  Event grouping, bucketing, and roll-up utilities shared across analytics
  modules via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Analytics.StatUtils  # propagates statistical dependency into every caller

      def group_by_key(events, key) do
        Enum.group_by(events, fn e -> Map.get(e, key) end)
      end

      def count_by_key(events, key) do
        events
        |> group_by_key(key)
        |> Enum.map(fn {k, v} -> {k, length(v)} end)
        |> Map.new()
      end

      def sum_by_key(events, group_key, value_key) do
        events
        |> group_by_key(group_key)
        |> Enum.map(fn {k, items} ->
          {k, Enum.reduce(items, 0, fn e, acc -> acc + Map.get(e, value_key, 0) end)}
        end)
        |> Map.new()
      end

      def bucket_by_hour(events, ts_key \\ :occurred_at) do
        Enum.group_by(events, fn e ->
          e
          |> Map.get(ts_key)
          |> DateTime.truncate(:second)
          |> then(&%{&1 | minute: 0, second: 0})
        end)
      end

      def top_n(events, key, n) do
        events
        |> count_by_key(key)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(n)
      end
    end
  end
end

defmodule Analytics.EventAggregator do
  @moduledoc """
  Aggregates raw platform events into summary metrics, funnel stages,
  retention buckets, and anomaly flags for the analytics dashboard.
  """

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Analytics.AggregationHelpers`
  # VALIDATION: triggers `__using__/1`, which injects `import Analytics.StatUtils`
  # VALIDATION: into `EventAggregator`. Statistical functions such as `std_dev/1`,
  # VALIDATION: `percentile/2`, and `z_score/3` silently enter this module's
  # VALIDATION: namespace. The aggregator only needs the grouping and counting
  # VALIDATION: helpers; `import Analytics.AggregationHelpers` would expose only
  # VALIDATION: what is intentionally needed.
  use Analytics.AggregationHelpers
  # VALIDATION: SMELL END

  @funnel_stages [:page_view, :signup_start, :signup_complete, :first_purchase]

  def summarize(events, window_start, window_end) do
    in_window =
      Enum.filter(events, fn e ->
        DateTime.compare(e.occurred_at, window_start) in [:gt, :eq] and
          DateTime.compare(e.occurred_at, window_end) in [:lt, :eq]
      end)

    %{
      total_events:    length(in_window),
      by_type:         count_by_key(in_window, :type),
      by_user:         count_by_key(in_window, :user_id),
      top_pages:       top_n(in_window, :page, 10),
      hourly_buckets:  bucket_by_hour(in_window) |> Enum.map(fn {h, evts} -> {h, length(evts)} end),
      window_start:    window_start,
      window_end:      window_end
    }
  end

  def funnel_analysis(events, user_id) do
    user_events =
      events
      |> Enum.filter(&(&1.user_id == user_id))
      |> Enum.sort_by(& &1.occurred_at)
      |> Enum.map(& &1.type)

    @funnel_stages
    |> Enum.reduce_while([], fn stage, completed ->
      if stage in user_events do
        {:cont, [stage | completed]}
      else
        {:halt, completed}
      end
    end)
    |> Enum.reverse()
  end

  def retention_cohort(events, cohort_date) do
    cohort_users =
      events
      |> Enum.filter(fn e ->
        e.type == :signup_complete and
          Date.compare(DateTime.to_date(e.occurred_at), cohort_date) == :eq
      end)
      |> Enum.map(& &1.user_id)
      |> MapSet.new()

    day_buckets = bucket_by_hour(events)

    Enum.map(day_buckets, fn {hour, hour_events} ->
      returning =
        hour_events
        |> Enum.filter(&MapSet.member?(cohort_users, &1.user_id))
        |> Enum.uniq_by(& &1.user_id)
        |> length()

      {hour, returning}
    end)
  end

  def anomaly_flags(events, metric_key) do
    counts  = sum_by_key(events, :hour, metric_key) |> Map.values()
    avg     = if counts == [], do: 0, else: Enum.sum(counts) / length(counts)
    sd      = std_dev(counts)
    cutoff  = avg + 2 * sd

    events
    |> group_by_key(:hour)
    |> Enum.filter(fn {_, hour_events} ->
      total = Enum.reduce(hour_events, 0, &(Map.get(&1, metric_key, 0) + &2))
      total > cutoff
    end)
    |> Enum.map(fn {hour, _} -> hour end)
  end
end
```
