# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Lending.LoanEvaluator.evaluate/1`, where optional applicant financial fields are accessed dynamically
- **Affected function(s):** `evaluate/1`
- **Short explanation:** The function reads `:existing_debt_usd`, `:bankruptcy_flag`, and `:collateral_value_usd` from the application map using bracket access. Missing keys return `nil`, so debt-to-income and collateral calculations silently operate on `nil`, producing incorrect credit decisions without surfacing that input data is incomplete.

```elixir
defmodule Lending.LoanEvaluator do
  @moduledoc """
  Evaluates personal loan applications using a rule-based credit model.
  Assesses income, existing debt obligations, credit score, collateral,
  and adverse history to produce an approval decision with a risk tier.
  """

  require Logger

  @min_credit_score      580
  @max_dti_ratio         0.43
  @min_annual_income_usd 18_000
  @risk_tiers            [:prime, :near_prime, :subprime]

  @type application :: %{
          id: String.t(),
          applicant_id: String.t(),
          requested_amount_usd: float(),
          annual_income_usd: float(),
          credit_score: non_neg_integer(),
          loan_purpose: String.t(),
          term_months: pos_integer(),
          optional(:existing_debt_usd) => float(),
          optional(:bankruptcy_flag) => boolean(),
          optional(:collateral_value_usd) => float(),
          optional(:co_applicant_income_usd) => float()
        }

  @spec evaluate(application()) :: {:ok, map()} | {:error, String.t()}
  def evaluate(application) do
    with :ok <- validate_application(application),
         {:ok, decision} <- run_credit_model(application) do
      Logger.info("Loan application #{application.id} evaluated: #{decision.status}")
      {:ok, decision}
    end
  end

  defp validate_application(app) do
    cond do
      app.requested_amount_usd <= 0 ->
        {:error, "requested amount must be positive"}

      app.term_months not in [12, 24, 36, 48, 60] ->
        {:error, "invalid loan term: #{app.term_months} months"}

      app.annual_income_usd < @min_annual_income_usd ->
        {:error, "annual income below minimum threshold"}

      true ->
        :ok
    end
  end

  defp run_credit_model(app) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `app[:existing_debt_usd]`,
    # `app[:bankruptcy_flag]`, and `app[:collateral_value_usd]` use dynamic
    # bracket access on a plain map. When any key is absent, `nil` is returned.
    # `nil` for `existing_debt_usd` makes the DTI calculation `nil / income`,
    # which returns `nil` and silently passes the DTI check instead of raising
    # a data error. A missing `bankruptcy_flag` is indistinguishable from
    # a clean credit history, hiding a critical underwriting input.
    existing_debt_usd    = app[:existing_debt_usd]
    bankruptcy_flag      = app[:bankruptcy_flag]
    collateral_value_usd = app[:collateral_value_usd]
    # VALIDATION: SMELL END

    co_income    = app[:co_applicant_income_usd] || 0.0
    total_income = app.annual_income_usd + co_income

    monthly_income     = total_income / 12.0
    monthly_debt       = (existing_debt_usd || 0.0) / 12.0
    proposed_payment   = estimate_monthly_payment(app.requested_amount_usd, app.term_months)
    dti                = (monthly_debt + proposed_payment) / monthly_income

    risk_tier = assign_risk_tier(app.credit_score)

    cond do
      bankruptcy_flag ->
        build_decision(app, :declined, risk_tier, "adverse credit history: bankruptcy on record")

      app.credit_score < @min_credit_score ->
        build_decision(app, :declined, risk_tier, "credit score #{app.credit_score} below minimum")

      dti > @max_dti_ratio ->
        build_decision(app, :declined, risk_tier, "DTI ratio #{Float.round(dti, 2)} exceeds maximum #{@max_dti_ratio}")

      not is_nil(collateral_value_usd) and collateral_value_usd >= app.requested_amount_usd * 0.8 ->
        build_decision(app, :approved_secured, risk_tier, "collateral sufficient")

      risk_tier == :prime ->
        build_decision(app, :approved, risk_tier, "prime applicant; unsecured approval")

      risk_tier == :near_prime ->
        build_decision(app, :approved_with_conditions, risk_tier, "near-prime; subject to additional review")

      true ->
        build_decision(app, :declined, risk_tier, "subprime profile does not meet unsecured lending criteria")
    end
  end

  defp assign_risk_tier(score) when score >= 720, do: :prime
  defp assign_risk_tier(score) when score >= 660, do: :near_prime
  defp assign_risk_tier(_),                       do: :subprime

  defp estimate_monthly_payment(principal, term_months) do
    annual_rate   = 0.12
    monthly_rate  = annual_rate / 12.0
    factor        = :math.pow(1 + monthly_rate, term_months)
    Float.round(principal * monthly_rate * factor / (factor - 1), 2)
  end

  defp build_decision(app, status, risk_tier, reason) do
    decision = %{
      application_id: app.id,
      applicant_id:   app.applicant_id,
      status:         status,
      risk_tier:      risk_tier,
      reason:         reason,
      evaluated_at:   DateTime.utc_now()
    }
    {:ok, decision}
  end
end
```
