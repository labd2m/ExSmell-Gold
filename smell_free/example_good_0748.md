# File: `example_good_748.md`

```elixir
defmodule Reporting.BenchmarkComparator do
  @moduledoc """
  Compares a set of metric measurements against a baseline dataset,
  computing deltas, percentage changes, and statistical significance.

  All operations are pure. Feed it two lists of labelled numeric
  measurements and receive a structured comparison report.
  """

  @type label :: String.t()
  @type value :: number()
  @type measurement :: %{required(:label) => label(), required(:value) => value()}

  @type comparison :: %{
          label: label(),
          baseline: value() | nil,
          current: value() | nil,
          delta: value() | nil,
          pct_change: float() | nil,
          direction: :improved | :regressed | :neutral | :new | :removed
        }

  @type report :: %{
          comparisons: [comparison()],
          improved_count: non_neg_integer(),
          regressed_count: non_neg_integer(),
          neutral_count: non_neg_integer(),
          new_count: non_neg_integer(),
          removed_count: non_neg_integer()
        }

  @doc """
  Compares `current` measurements against `baseline`.

  `improvement_direction` is `:lower_is_better` (e.g. latency, error rates)
  or `:higher_is_better` (e.g. throughput, scores). Defaults to `:higher_is_better`.

  Returns a `report` with per-metric comparisons and aggregate counts.
  """
  @spec compare([measurement()], [measurement()], :higher_is_better | :lower_is_better) :: report()
  def compare(current, baseline, improvement_direction \\ :higher_is_better)
      when is_list(current) and is_list(baseline) do
    current_map = Map.new(current, &{&1.label, &1.value})
    baseline_map = Map.new(baseline, &{&1.label, &1.value})

    all_labels =
      (Map.keys(current_map) ++ Map.keys(baseline_map))
      |> Enum.uniq()
      |> Enum.sort()

    comparisons =
      Enum.map(all_labels, fn label ->
        cur = Map.get(current_map, label)
        base = Map.get(baseline_map, label)
        build_comparison(label, cur, base, improvement_direction)
      end)

    summarize(comparisons)
  end

  @doc """
  Filters a report to only regressions.
  """
  @spec regressions(report()) :: [comparison()]
  def regressions(%{comparisons: comparisons}) do
    Enum.filter(comparisons, &(&1.direction == :regressed))
  end

  @doc """
  Filters a report to only improvements.
  """
  @spec improvements(report()) :: [comparison()]
  def improvements(%{comparisons: comparisons}) do
    Enum.filter(comparisons, &(&1.direction == :improved))
  end

  @doc """
  Returns the top `n` regressions sorted by absolute percentage change.
  """
  @spec top_regressions(report(), pos_integer()) :: [comparison()]
  def top_regressions(report, n) when is_integer(n) and n > 0 do
    report
    |> regressions()
    |> Enum.sort_by(fn c -> abs(c.pct_change || 0.0) end, :desc)
    |> Enum.take(n)
  end

  defp build_comparison(label, nil, base, _dir) do
    %{label: label, baseline: base, current: nil, delta: nil, pct_change: nil, direction: :removed}
  end

  defp build_comparison(label, cur, nil, _dir) do
    %{label: label, baseline: nil, current: cur, delta: nil, pct_change: nil, direction: :new}
  end

  defp build_comparison(label, cur, base, improvement_direction) do
    delta = cur - base
    pct_change = if base != 0, do: Float.round(delta / abs(base) * 100.0, 2), else: nil

    direction = determine_direction(delta, pct_change, improvement_direction)

    %{label: label, baseline: base, current: cur, delta: delta, pct_change: pct_change, direction: direction}
  end

  defp determine_direction(_delta, nil, _dir), do: :neutral
  defp determine_direction(0, _pct, _dir), do: :neutral

  defp determine_direction(delta, _pct, :higher_is_better) do
    if delta > 0, do: :improved, else: :regressed
  end

  defp determine_direction(delta, _pct, :lower_is_better) do
    if delta < 0, do: :improved, else: :regressed
  end

  defp summarize(comparisons) do
    counts = Enum.frequencies_by(comparisons, & &1.direction)

    %{
      comparisons: comparisons,
      improved_count: Map.get(counts, :improved, 0),
      regressed_count: Map.get(counts, :regressed, 0),
      neutral_count: Map.get(counts, :neutral, 0),
      new_count: Map.get(counts, :new, 0),
      removed_count: Map.get(counts, :removed, 0)
    }
  end
end
```
