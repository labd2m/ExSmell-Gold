# Annotated Example 17

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Lending.LoanEvaluator.evaluate/2`, lines where `application` map keys are accessed dynamically
- **Affected function(s):** `evaluate/2`
- **Short explanation:** `application[:requested_amount]`, `application[:term_months]`, `application[:annual_income]`, and `application[:credit_score]` use dynamic bracket access. A missing `:credit_score` silently returns `nil`, which flows into a numeric comparison and causes an incorrect approval decision rather than surfacing a missing-field error.

---

```elixir
defmodule Lending.LoanEvaluator do
  @moduledoc """
  Evaluates personal loan applications against lending policy rules,
  computes a risk score, and returns an approval decision with terms.
  """

  require Logger

  @min_credit_score    580
  @max_dti_ratio       0.45
  @base_interest_rate  0.089
  @risk_spread_per_pt  0.0002

  @type decision :: :approved | :declined | :manual_review

  @spec evaluate(map(), map()) ::
          {:ok, %{decision: decision(), rate: float(), notes: list(String.t())}}
          | {:error, String.t()}
  def evaluate(application, policy_overrides \\ %{}) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `application[:requested_amount]`,
    # `application[:term_months]`, `application[:annual_income]`, and
    # `application[:credit_score]` use dynamic bracket access. When
    # `:credit_score` is absent, `nil` is returned and compared against
    # `@min_credit_score` via `<`, which evaluates to `false` in Elixir (nil
    # is not a number), silently treating a missing score as acceptable and
    # potentially approving an application that should be declined or flagged.
    requested_amount = application[:requested_amount]
    term_months      = application[:term_months]
    annual_income    = application[:annual_income]
    credit_score     = application[:credit_score]
    # VALIDATION: SMELL END

    with :ok <- validate_required_fields(requested_amount, term_months, annual_income, credit_score),
         :ok <- validate_ranges(requested_amount, term_months, annual_income) do
      policy     = Map.merge(default_policy(), policy_overrides)
      dti_ratio  = compute_dti(requested_amount, term_months, annual_income)
      risk_score = compute_risk_score(credit_score, dti_ratio)

      {decision, notes} = decide(credit_score, dti_ratio, risk_score, policy)
      rate              = compute_rate(risk_score)

      Logger.info("Loan application evaluated",
        applicant_id: Map.get(application, :applicant_id),
        decision: decision,
        risk_score: risk_score,
        rate: rate
      )

      {:ok, %{decision: decision, rate: rate, risk_score: risk_score, notes: notes}}
    end
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_required_fields(amount, term, income, score) do
    missing =
      [requested_amount: amount, term_months: term, annual_income: income, credit_score: score]
      |> Enum.filter(fn {_k, v} -> is_nil(v) end)
      |> Keyword.keys()

    if missing == [] do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_ranges(amount, term, income) do
    cond do
      amount <= 0      -> {:error, "Requested amount must be positive"}
      term not in 12..84 -> {:error, "Term must be between 12 and 84 months"}
      income <= 0      -> {:error, "Annual income must be positive"}
      true             -> :ok
    end
  end

  # ── Computation ─────────────────────────────────────────────────────────────

  defp compute_dti(amount, term_months, annual_income) do
    monthly_payment = amount / term_months
    monthly_income  = annual_income / 12
    Float.round(monthly_payment / monthly_income, 4)
  end

  defp compute_risk_score(credit_score, dti_ratio) do
    base       = (credit_score - 300) / 550
    dti_factor = 1 - dti_ratio
    Float.round(base * dti_factor * 100, 2)
  end

  defp compute_rate(risk_score) do
    spread = (100 - risk_score) * @risk_spread_per_pt
    Float.round(@base_interest_rate + spread, 4)
  end

  defp decide(credit_score, dti_ratio, risk_score, policy) do
    notes = []

    cond do
      credit_score < policy.min_credit_score ->
        {:declined, ["Credit score #{credit_score} below minimum #{policy.min_credit_score}" | notes]}

      dti_ratio > policy.max_dti_ratio ->
        {:declined, ["DTI ratio #{dti_ratio} exceeds maximum #{policy.max_dti_ratio}" | notes]}

      risk_score < 40 ->
        {:manual_review, ["Risk score #{risk_score} requires underwriter review" | notes]}

      true ->
        {:approved, notes}
    end
  end

  defp default_policy do
    %{min_credit_score: @min_credit_score, max_dti_ratio: @max_dti_ratio}
  end
end
```
