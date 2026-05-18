# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Reporting.ScoreCalculator` module, `weighted_score/2` macro |
| **Affected function(s)** | `weighted_score/2` |
| **Short explanation** | `weighted_score/2` computes a weighted average from two runtime lists using `Enum.zip/2` and arithmetic. Every step occurs at runtime; a regular function is the correct abstraction and would be far more readable and testable. |

```elixir
defmodule Reporting.ScoreCalculator do
  @moduledoc """
  Computes composite quality and performance scores for vendor evaluations,
  employee assessments, and customer satisfaction surveys using configurable
  weighted criteria.
  """

  @score_precision 2

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `weighted_score/2` receives two
  # runtime lists and performs `Enum.zip`, mapping, and summing — all
  # runtime operations. Defining this as a macro adds `quote/unquote`
  # ceremony without offering any compile-time optimisation. A `def`
  # function would be cleaner, directly testable, and callable without
  # a `require` directive.
  defmacro weighted_score(scores, weights) do
    quote do
      pairs = Enum.zip(unquote(scores), unquote(weights))
      total_weight = Enum.sum(unquote(weights))

      raw =
        Enum.reduce(pairs, 0.0, fn {score, weight}, acc ->
          acc + score * weight
        end) / total_weight

      Float.round(raw, unquote(@score_precision))
    end
  end
  # VALIDATION: SMELL END

  def evaluate_vendor(vendor, criteria) do
    require Reporting.ScoreCalculator

    scores = Enum.map(criteria, fn c -> Map.get(vendor.ratings, c.name, 0) end)
    weights = Enum.map(criteria, & &1.weight)

    overall = Reporting.ScoreCalculator.weighted_score(scores, weights)

    %{
      vendor_id: vendor.id,
      vendor_name: vendor.name,
      overall_score: overall,
      grade: grade_for(overall),
      criteria_scores: Enum.zip(criteria, scores) |> Enum.map(fn {c, s} -> {c.name, s} end)
    }
  end

  def evaluate_employee(employee, kpis) do
    require Reporting.ScoreCalculator

    scores = Enum.map(kpis, fn kpi -> Map.get(employee.kpi_results, kpi.id, 0.0) end)
    weights = Enum.map(kpis, & &1.weight)

    overall = Reporting.ScoreCalculator.weighted_score(scores, weights)

    %{
      employee_id: employee.id,
      name: employee.name,
      score: overall,
      grade: grade_for(overall),
      period: employee.evaluation_period
    }
  end

  def evaluate_nps(responses, dimension_weights) do
    require Reporting.ScoreCalculator

    dimensions = Map.keys(dimension_weights)
    scores = Enum.map(dimensions, fn d -> avg_response(responses, d) end)
    weights = Enum.map(dimensions, &Map.get(dimension_weights, &1))

    Reporting.ScoreCalculator.weighted_score(scores, weights)
  end

  defp avg_response(responses, dimension) do
    relevant = Enum.filter(responses, &Map.has_key?(&1, dimension))

    if Enum.empty?(relevant) do
      0.0
    else
      total = Enum.reduce(relevant, 0.0, fn r, acc -> acc + Map.get(r, dimension) end)
      total / length(relevant)
    end
  end

  def rank_vendors(vendors, criteria) do
    vendors
    |> Enum.map(&evaluate_vendor(&1, criteria))
    |> Enum.sort_by(& &1.overall_score, :desc)
    |> Enum.with_index(1)
    |> Enum.map(fn {v, rank} -> Map.put(v, :rank, rank) end)
  end

  defp grade_for(score) when score >= 90, do: "A"
  defp grade_for(score) when score >= 75, do: "B"
  defp grade_for(score) when score >= 60, do: "C"
  defp grade_for(score) when score >= 45, do: "D"
  defp grade_for(_), do: "F"
end
```
