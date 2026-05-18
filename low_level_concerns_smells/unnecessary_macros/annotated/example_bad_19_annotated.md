# Annotated Example 19 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro safe_divide/2` inside `Reporting.MathUtils`
- **Affected function(s):** `safe_divide/2`
- **Short explanation:** The macro performs guarded division returning `0.0` when the divisor is zero — a trivial runtime arithmetic guard. A regular function (or even a simple inline check) handles this without the overhead and confusion of a macro.

---

```elixir
defmodule Reporting.MathUtils do
  @moduledoc """
  Arithmetic helpers used in reporting calculations, including ratio
  computation, growth rate analysis, and percentage formatting.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because safe_divide/2 guards a division
  # against a zero denominator at runtime. This is a straightforward
  # runtime check; a normal def function is cleaner and easier to test.
  defmacro safe_divide(numerator, denominator) do
    quote do
      denom = unquote(denominator)
      if denom == 0, do: 0.0, else: unquote(numerator) / denom
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Computes the period-over-period growth rate as a percentage.
  Returns `nil` when the previous period value is zero.
  """
  @spec growth_rate(number(), number()) :: float() | nil
  def growth_rate(_current, 0), do: nil

  def growth_rate(current, previous) do
    (current - previous) / previous * 100.0
  end

  @doc """
  Formats a float ratio as a percentage string with the given decimal places.
  """
  @spec format_pct(float(), non_neg_integer()) :: String.t()
  def format_pct(ratio, decimals \\ 2) do
    "#{Float.round(ratio * 100.0, decimals)}%"
  end

  @doc """
  Rounds a float to the nearest integer cent (for display purposes).
  """
  @spec round_cents(float()) :: integer()
  def round_cents(value), do: round(value)
end

defmodule Reporting.ConversionAnalysis do
  @moduledoc """
  Analyses funnel conversion rates across user acquisition, activation,
  and retention stages. Feeds the growth and product dashboards.
  """

  require Reporting.MathUtils

  alias Reporting.MathUtils

  @doc """
  Computes conversion rates for each stage in a funnel definition.
  Each stage is compared to both the previous stage and the top of funnel.
  """
  @spec compute_funnel(list(map())) :: list(map())
  def compute_funnel([]), do: []

  def compute_funnel(stages) do
    top_of_funnel = hd(stages).count

    stages
    |> Enum.with_index()
    |> Enum.map(fn {stage, idx} ->
      prev_count =
        if idx == 0, do: stage.count, else: Enum.at(stages, idx - 1).count

      step_rate = MathUtils.safe_divide(stage.count, prev_count)
      overall_rate = MathUtils.safe_divide(stage.count, top_of_funnel)

      %{
        stage: stage.name,
        count: stage.count,
        step_conversion_rate: step_rate,
        overall_conversion_rate: overall_rate,
        step_conversion_pct: MathUtils.format_pct(step_rate),
        overall_conversion_pct: MathUtils.format_pct(overall_rate)
      }
    end)
  end

  @doc """
  Computes the average revenue per user (ARPU) for a cohort.
  """
  @spec arpu(non_neg_integer(), non_neg_integer()) :: float()
  def arpu(total_revenue_cents, user_count) do
    MathUtils.safe_divide(total_revenue_cents, user_count)
  end

  @doc """
  Computes the churn rate for a given period.
  """
  @spec churn_rate(non_neg_integer(), non_neg_integer()) :: float()
  def churn_rate(churned_users, total_users_at_start) do
    MathUtils.safe_divide(churned_users, total_users_at_start)
  end

  @doc """
  Builds a full cohort health summary from metric inputs.
  """
  @spec cohort_summary(map()) :: map()
  def cohort_summary(%{
        cohort_id: id,
        users: users,
        churned: churned,
        revenue_cents: revenue,
        sessions: sessions
      }) do
    %{
      cohort_id: id,
      user_count: users,
      churn_rate: MathUtils.format_pct(churn_rate(churned, users)),
      arpu_cents: MathUtils.round_cents(arpu(revenue, users)),
      avg_sessions_per_user: Float.round(MathUtils.safe_divide(sessions, users), 2)
    }
  end
end
```
