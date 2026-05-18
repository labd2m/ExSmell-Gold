# Annotated Example 13 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro weighted_average/2` inside `Reporting.Statistics`
- **Affected function(s):** `weighted_average/2`
- **Short explanation:** The macro computes a weighted average using `Enum.reduce` over runtime lists — a standard data aggregation that needs no compile-time transformation. A regular function is simpler and more testable.

---

```elixir
defmodule Reporting.Statistics do
  @moduledoc """
  Statistical aggregation utilities for reporting pipelines.
  Used in KPI dashboards, performance summaries, and forecast models.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because weighted_average/2 only performs
  # runtime list reductions (Enum.reduce). The computation is entirely
  # data-driven and runtime; a normal function would be cleaner and testable
  # without requiring the caller module to `require` this module.
  defmacro weighted_average(values, weights) do
    quote do
      vals = unquote(values)
      wts = unquote(weights)

      {weighted_sum, total_weight} =
        Enum.zip(vals, wts)
        |> Enum.reduce({0.0, 0.0}, fn {v, w}, {sum, weight_sum} ->
          {sum + v * w, weight_sum + w}
        end)

      if total_weight == 0.0, do: 0.0, else: weighted_sum / total_weight
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Computes the arithmetic mean of a list of numbers.
  """
  @spec mean(list(number())) :: float()
  def mean([]), do: 0.0

  def mean(values) do
    Enum.sum(values) / length(values)
  end

  @doc """
  Computes the standard deviation of a list of numbers.
  """
  @spec std_dev(list(number())) :: float()
  def std_dev([]), do: 0.0

  def std_dev(values) do
    avg = mean(values)
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + (v - avg) ** 2 end) / length(values)
    :math.sqrt(variance)
  end

  @doc """
  Returns the median value of a list of numbers.
  """
  @spec median(list(number())) :: float()
  def median([]), do: 0.0

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    else
      Enum.at(sorted, mid) * 1.0
    end
  end
end

defmodule Reporting.KPIDashboard do
  @moduledoc """
  Computes KPI metrics for the executive dashboard, including weighted scores,
  performance bands, and period-over-period comparisons.
  """

  require Reporting.Statistics

  alias Reporting.Statistics

  @kpi_weights %{
    revenue_growth: 0.40,
    customer_satisfaction: 0.30,
    churn_rate: 0.20,
    support_resolution_time: 0.10
  }

  @doc """
  Computes the composite KPI score for a given period's metrics.
  """
  @spec composite_score(map()) :: float()
  def composite_score(%{
        revenue_growth: rg,
        customer_satisfaction: cs,
        churn_rate: cr,
        support_resolution_time: srt
      }) do
    values = [rg, cs, 1.0 - cr, 1.0 - srt]

    weights = [
      @kpi_weights.revenue_growth,
      @kpi_weights.customer_satisfaction,
      @kpi_weights.churn_rate,
      @kpi_weights.support_resolution_time
    ]

    Statistics.weighted_average(values, weights)
  end

  @doc """
  Returns a performance band label based on composite score.
  """
  @spec performance_band(float()) :: :excellent | :good | :fair | :poor
  def performance_band(score) do
    cond do
      score >= 0.85 -> :excellent
      score >= 0.70 -> :good
      score >= 0.50 -> :fair
      true -> :poor
    end
  end

  @doc """
  Generates a summary report for a list of period metric snapshots.
  """
  @spec generate_summary(list(map())) :: map()
  def generate_summary(periods) do
    scores = Enum.map(periods, &composite_score/1)

    %{
      period_count: length(periods),
      mean_score: Statistics.mean(scores),
      median_score: Statistics.median(scores),
      score_std_dev: Statistics.std_dev(scores),
      latest_score: List.last(scores),
      latest_band: List.last(scores) |> performance_band()
    }
  end
end
```
