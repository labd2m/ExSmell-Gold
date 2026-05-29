# Annotated Example 32 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Lending.Applications.submit_loan_application/11` |
| **Affected function(s)** | `submit_loan_application/11` |
| **Explanation** | The function takes 11 individual parameters covering applicant identity (applicant_id, full_name, national_id, email), financial profile (annual_income, employment_status, credit_score), and loan request details (amount, purpose, term_months, collateral_description). These form three natural groupings that should each be a dedicated struct, not a long flat argument list. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `submit_loan_application/11` accepts
# eleven positional parameters. Applicant identity (applicant_id, full_name,
# national_id, email), financial profile data (annual_income,
# employment_status, credit_score), and loan request specifics (amount,
# purpose, term_months, collateral_description) are all passed as a flat
# list. With eleven arguments — many of them numeric — argument-order
# mistakes are likely and the call site is impossible to read at a glance.
defmodule Lending.Applications do
  @moduledoc """
  Processes loan applications through eligibility checks, risk scoring,
  and underwriting queue submission.
  """

  require Logger

  alias Lending.Repo
  alias Lending.Schemas.LoanApplication
  alias Lending.Schemas.CreditEvent
  alias Lending.RiskEngine
  alias Lending.Mailer

  @valid_employment_statuses ~w(employed self_employed unemployed retired)
  @valid_purposes ~w(home_purchase renovation vehicle education business personal)
  @min_loan_amount 1_000
  @max_loan_amount 500_000
  @min_term_months 6
  @max_term_months 360

  def submit_loan_application(
        applicant_id,
        full_name,
        national_id,
        email,
        annual_income,
        employment_status,
        credit_score,
        amount,
        purpose,
        term_months,
        collateral_description
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_identity(full_name, national_id, email),
         :ok <- validate_financial_profile(annual_income, employment_status, credit_score),
         :ok <- validate_loan_request(amount, purpose, term_months) do
      risk = RiskEngine.score(%{
        annual_income: annual_income,
        credit_score: credit_score,
        employment_status: employment_status,
        loan_amount: amount,
        term_months: term_months
      })

      initial_status =
        cond do
          risk.score >= 750 -> :pre_approved
          risk.score >= 600 -> :under_review
          true -> :declined
        end

      application_attrs = %{
        applicant_id: applicant_id,
        full_name: full_name,
        national_id_hash: :crypto.hash(:sha256, national_id) |> Base.encode16(),
        email: String.downcase(String.trim(email)),
        annual_income: annual_income,
        employment_status: employment_status,
        credit_score: credit_score,
        amount: amount,
        purpose: purpose,
        term_months: term_months,
        collateral_description: collateral_description,
        risk_score: risk.score,
        risk_band: risk.band,
        status: initial_status,
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(LoanApplication.changeset(%LoanApplication{}, application_attrs)) do
        {:ok, application} ->
          Repo.insert!(CreditEvent.changeset(%CreditEvent{}, %{
            applicant_id: applicant_id,
            application_id: application.id,
            event_type: :application_submitted,
            occurred_at: DateTime.utc_now()
          }))

          Mailer.send_application_receipt(email, full_name, application)
          Logger.info("Loan application #{application.id} submitted, status=#{initial_status}")
          {:ok, application}

        {:error, changeset} ->
          Logger.error("Loan application failed: #{inspect(changeset.errors)}")
          {:error, :submission_failed}
      end
    end
  end

  defp validate_identity(name, national_id, email) do
    cond do
      is_nil(name) or String.trim(name) == "" -> {:error, :missing_full_name}
      not Regex.match?(~r/^[A-Z0-9\-]{6,20}$/i, national_id || "") -> {:error, :invalid_national_id}
      not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") -> {:error, :invalid_email}
      true -> :ok
    end
  end

  defp validate_financial_profile(income, status, score) do
    cond do
      not is_number(income) or income < 0 -> {:error, :invalid_annual_income}
      status not in @valid_employment_statuses -> {:error, {:unknown_employment_status, status}}
      not is_integer(score) or score < 300 or score > 850 -> {:error, :invalid_credit_score}
      true -> :ok
    end
  end

  defp validate_loan_request(amount, purpose, term) do
    cond do
      not is_number(amount) or amount < @min_loan_amount or amount > @max_loan_amount ->
        {:error, {:amount_out_of_range, @min_loan_amount, @max_loan_amount}}

      purpose not in @valid_purposes ->
        {:error, {:unknown_loan_purpose, purpose}}

      not is_integer(term) or term < @min_term_months or term > @max_term_months ->
        {:error, :invalid_term_months}

      true ->
        :ok
    end
  end
end
```
