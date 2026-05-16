```elixir
defmodule Lending.LoanApplicationService do
  alias Lending.{Repo, Applicant, CreditBureau, RiskEngine, ComplianceChecker, LoanApplication}

  require Logger

  @min_credit_score 580
  @max_dti_ratio 0.43

  def submit_loan_application(applicant_id, loan_params) do
    amount = Map.fetch!(loan_params, :amount_cents)
    term_months = Map.fetch!(loan_params, :term_months)
    purpose = Map.get(loan_params, :purpose, :personal)

    with {:ok, applicant} <- fetch_eligible_applicant(applicant_id),
         {:ok, credit_report} <- CreditBureau.pull_report(applicant.ssn_hash, applicant.id),
         {:ok, risk_score} <- RiskEngine.score(applicant, credit_report, amount, term_months),
         :ok <- ComplianceChecker.run(applicant, credit_report, amount, purpose),
         {:ok, application} <- create_application(applicant, risk_score, loan_params) do
      Logger.info(
        "Loan application #{application.id} submitted: " <>
          "applicant=#{applicant_id} amount=#{amount} score=#{risk_score.value}"
      )

      {:ok, %{application_id: application.id, risk_score: risk_score.value, status: application.status}}
    else
      {:error, :applicant_not_found} ->
        Logger.warning("Applicant #{applicant_id} not found")
        {:error, :applicant_not_found}

      {:error, :applicant_ineligible} ->
        Logger.warning("Applicant #{applicant_id} is not eligible for a loan")
        {:error, :applicant_ineligible}

      {:error, :bureau_unavailable} ->
        Logger.error("Credit bureau unavailable for applicant #{applicant_id}")
        {:error, :credit_check_unavailable}

      {:error, :bureau_frozen} ->
        Logger.warning("Credit is frozen for applicant #{applicant_id}")
        {:error, :credit_frozen}

      {:error, :no_report} ->
        Logger.warning("No credit report found for applicant #{applicant_id}")
        {:error, :no_credit_history}

      {:error, {:risk_model_error, reason}} ->
        Logger.error("Risk model error for #{applicant_id}: #{inspect(reason)}")
        {:error, :risk_engine_error}

      {:error, :below_minimum_score} ->
        Logger.info("Applicant #{applicant_id} declined: credit score below minimum")
        {:error, :credit_score_insufficient}

      {:error, :ofac_hit} ->
        Logger.warning("OFAC compliance hit for applicant #{applicant_id}")
        {:error, :compliance_rejected}

      {:error, :state_restriction} ->
        Logger.warning("State restriction applies to applicant #{applicant_id}")
        {:error, :compliance_rejected}

      {:error, :dti_too_high} ->
        Logger.info("Applicant #{applicant_id} declined: DTI ratio exceeds maximum")
        {:error, :dti_exceeded}

      {:error, :db_error} ->
        Logger.error("Application persistence failed for applicant #{applicant_id}")
        {:error, :application_creation_failed}
    end
  end

  defp fetch_eligible_applicant(applicant_id) do
    case Repo.get(Applicant, applicant_id) do
      nil -> {:error, :applicant_not_found}
      %Applicant{eligible: false} -> {:error, :applicant_ineligible}
      applicant -> {:ok, applicant}
    end
  end

  defp create_application(applicant, risk_score, loan_params) do
    initial_status = if risk_score.value >= @min_credit_score, do: :pending_review, else: :auto_declined

    %LoanApplication{}
    |> LoanApplication.changeset(%{
      applicant_id: applicant.id,
      amount_cents: loan_params.amount_cents,
      term_months: loan_params.term_months,
      purpose: loan_params[:purpose] || :personal,
      risk_score: risk_score.value,
      risk_tier: risk_score.tier,
      status: initial_status
    })
    |> Repo.insert()
    |> case do
      {:ok, app} -> {:ok, app}
      {:error, _} -> {:error, :db_error}
    end
  end
end
```
