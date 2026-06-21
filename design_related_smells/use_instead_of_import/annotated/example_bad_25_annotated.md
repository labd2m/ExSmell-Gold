# Annotated Bad Example 25

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Analytics.MetricReporter`, `use Analytics.FormatHelpers` directive
**Affected Functions:** `build_report/2`, `format_metric/2`, `top_n/3`, `compare_periods/2`
**Explanation:** `Analytics.MetricReporter` uses `use Analytics.FormatHelpers` to access number-formatting and percentage-computation helpers. However, `FormatHelpers.__using__/1` silently injects an alias for `Analytics.Cache` and sets `@cache_ttl_seconds` and `@chart_palette` module attributes into the calling module. A reader of `MetricReporter` cannot determine where `Cache` or those module attributes come from without reading the library macro. `import Analytics.FormatHelpers` would have been sufficient and would leave all dependencies visible.

```elixir
defmodule Analytics.FormatHelpers do
  @moduledoc """
  Pure formatting and aggregation utilities for analytics metric presentation.
  All functions are stateless and free of side-effects.
  """

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_number(n) when is_float(n), do: format_number(round(n))

  def format_percentage(ratio) when is_number(ratio) do
    "#{Float.round(ratio * 100, 1)}%"
  end

  def delta_percent(current, previous) when previous == 0 and current == 0, do: 0.0
  def delta_percent(current, _) when is_number(current), do: 100.0
  def delta_percent(current, previous) when is_number(current) and is_number(previous) do
    Float.round((current - previous) / previous * 100, 2)
  end

  def growth_label(pct) when pct > 0,  do: "+#{pct}% ▲"
  def growth_label(pct) when pct < 0,  do: "#{pct}% ▼"
  def growth_label(_),                 do: "0% →"

  def aggregate(rows, field) when is_list(rows) and is_atom(field) do
    values = Enum.map(rows, &Map.get(&1, field, 0))
    %{
      sum:  Enum.sum(values),
      avg:  if(length(values) > 0, do: Enum.sum(values) / length(values), else: 0),
      min:  Enum.min(values, fn -> 0 end),
      max:  Enum.max(values, fn -> 0 end),
      count: length(values)
    }
  end

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 propagates alias Analytics.Cache
  # and two module attributes into any caller. The caller has no explicit declaration
  # of these dependencies; they are hidden inside the macro and require knowledge
  # of the library's internals to discover.
  defmacro __using__(_opts) do
    quote do
      import Analytics.FormatHelpers
      alias Analytics.Cache

      @cache_ttl_seconds 300
      @chart_palette     ["#4C72B0", "#DD8452", "#55A868", "#C44E52"]
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Analytics.Cache do
  @moduledoc "Simple key-value cache stub for metric query results."

  def get(key) do
    case :ets.whereis(:analytics_cache) do
      :undefined -> nil
      _tid       -> :ets.lookup(:analytics_cache, key) |> List.first() |> then(fn
        {_k, v} -> v
        nil     -> nil
      end)
    end
  end

  def put(key, value, _ttl) do
    if :ets.whereis(:analytics_cache) == :undefined do
      :ets.new(:analytics_cache, [:set, :public, :named_table])
    end
    :ets.insert(:analytics_cache, {key, value})
    :ok
  end
end

defmodule Analytics.MetricReporter do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Analytics.FormatHelpers` silently
  # injects alias Analytics.Cache, @cache_ttl_seconds, and @chart_palette via
  # __using__/1. These are undeclared dependencies from the reader's perspective.
  # A plain `import Analytics.FormatHelpers` would suffice to access the formatting
  # functions, while all other dependencies would remain explicitly declared.
  use Analytics.FormatHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Builds analytics metric reports for dashboards, with period-over-period
  comparison, top-N ranking, and optional result caching.
  """

  def build_report(event_rows, opts \\ []) do
    period    = opts[:period] || :daily
    cache_key = "report:#{period}:#{:erlang.phash2(event_rows)}"

    case Cache.get(cache_key) do
      nil ->
        report = compute_report(event_rows, period)
        Cache.put(cache_key, report, @cache_ttl_seconds)
        {:ok, report}

      cached ->
        {:ok, Map.put(cached, :from_cache, true)}
    end
  end

  def compare_periods(current_rows, previous_rows) do
    curr = aggregate(current_rows, :value)
    prev = aggregate(previous_rows, :value)

    delta = delta_percent(curr.sum, prev.sum)

    %{
      current_sum:  format_number(curr.sum),
      previous_sum: format_number(prev.sum),
      current_avg:  format_number(curr.avg),
      previous_avg: format_number(prev.avg),
      growth:       growth_label(delta),
      delta_pct:    delta
    }
  end

  def top_n(rows, field, n) when is_atom(field) and is_integer(n) do
    rows
    |> Enum.sort_by(&Map.get(&1, field, 0), :desc)
    |> Enum.take(n)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} ->
      Map.merge(row, %{rank: rank, formatted_value: format_number(Map.get(row, field, 0))})
    end)
  end

  def format_metric(value, :percentage), do: format_percentage(value)
  def format_metric(value, :count),      do: format_number(value)
  def format_metric(value, :growth),     do: growth_label(value)
  def format_metric(value, _),           do: to_string(value)

  def palette, do: @chart_palette

  defp compute_report(rows, period) do
    stats = aggregate(rows, :value)
    %{
      period:       period,
      total:        format_number(stats.sum),
      average:      format_number(stats.avg),
      peak:         format_number(stats.max),
      data_points:  stats.count,
      generated_at: DateTime.utc_now()
    }
  end
end
```
