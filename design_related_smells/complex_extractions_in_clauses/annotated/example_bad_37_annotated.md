# Annotated Example 37 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                              |
|------------------------|----------------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                                     |
| **Expected location**  | `Lending.ApplicationProcessor.evaluate/1`                                                          |
| **Affected function**  | `evaluate/1`                                                                                       |
| **Short explanation**  | Each clause head extracts `product_type` (clause selection) and `credit_score` (guard), but also binds `application_id`, `applicant_id`, `requested_amount`, `annual_income`, and `employment_status` — five fields used exclusively inside the bodies. Across four clauses with seven extractions each, the reader must scan all bindings to isolate the two that drive dispatch. |

---

```elixir
defmodule Lending.ApplicationProcessor do
  @moduledoc """
  Evaluates loan applications based on product type and credit profile.
  Routes to automated approval, manual underwriting, or rejection
  depending on risk thresholds.
  """

  require Logger

  alias Lending.{
    CreditBureau,
    UnderwritingQueue,
    LoanOfferBuilder,
    ApplicationRepo,
    RiskScorer,
    AuditLog,
    ApplicantMailer
  }

  @auto_approve_credit_score 720
  @manual_review_credit_score 620
  @dti_limit 0.43

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `application_id`, `applicant_id`,
  # `requested_amount`, `annual_income`, and `employment_status` are extracted
  # in every clause head but are never referenced in guards or used for clause
  # selection. Only `product_type` selects the clause and `credit_score` feeds
  # the guards. Across four clauses with seven bindings each, isolating the
  # two dispatch-relevant bindings requires reading every field in every head.
  def evaluate(%Lending.Application{
        application_id: application_id,
        applicant_id: applicant_id,
        requested_amount: requested_amount,
        annual_income: annual_income,
        employment_status: employment_status,
        product_type: :personal_loan,
        credit_score: credit_score
      })
      when credit_score >= @auto_approve_credit_score do
    Logger.info(
      "[ApplicationProcessor] Auto-approving personal loan #{application_id} " <>
        "for applicant #{applicant_id} (score: #{credit_score})"
    )

    dti = calculate_dti(requested_amount, annual_income)

    if dti > @dti_limit do
      Logger.warning("[ApplicationProcessor] DTI #{dti} exceeds limit for #{application_id}")
      ApplicationRepo.update_status(application_id, :rejected, %{reason: :dti_exceeded})
      {:error, :dti_exceeded}
    else
      with {:ok, bureau_data} <- CreditBureau.pull_full_report(applicant_id),
           {:ok, offer} <- LoanOfferBuilder.build(:personal_loan, requested_amount, credit_score, bureau_data),
           {:ok, _} <- ApplicationRepo.update_status(application_id, :approved, %{offer_id: offer.id}),
           :ok <- ApplicantMailer.send_approval(applicant_id, offer),
           :ok <- AuditLog.write(:application_approved, applicant_id, %{
                    application_id: application_id,
                    product: :personal_loan,
                    amount: requested_amount,
                    income: annual_income,
                    employment: employment_status
                  }) do
        {:ok, :approved, offer}
      else
        {:error, reason} ->
          Logger.error("[ApplicationProcessor] Approval failed for #{application_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def evaluate(%Lending.Application{
        application_id: application_id,
        applicant_id: applicant_id,
        requested_amount: requested_amount,
        annual_income: annual_income,
        employment_status: employment_status,
        product_type: :personal_loan,
        credit_score: credit_score
      })
      when credit_score >= @manual_review_credit_score and credit_score < @auto_approve_credit_score do
    Logger.info(
      "[ApplicationProcessor] Queuing personal loan #{application_id} for manual underwriting " <>
        "(score: #{credit_score}, income: #{annual_income})"
    )

    risk_flags = RiskScorer.flag_risk_factors(applicant_id, requested_amount, employment_status)

    with {:ok, ticket_id} <- UnderwritingQueue.submit(application_id, :personal_loan, risk_flags),
         {:ok, _} <- ApplicationRepo.update_status(application_id, :under_review, %{ticket_id: ticket_id}),
         :ok <- ApplicantMailer.send_under_review_notice(applicant_id, application_id),
         :ok <- AuditLog.write(:application_queued, applicant_id, %{
                  application_id: application_id,
                  ticket_id: ticket_id,
                  credit_score: credit_score,
                  risk_flags: risk_flags
                }) do
      {:ok, :under_review, ticket_id}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def evaluate(%Lending.Application{
        application_id: application_id,
        applicant_id: applicant_id,
        requested_amount: requested_amount,
        annual_income: annual_income,
        employment_status: employment_status,
        product_type: :secured_loan,
        credit_score: credit_score
      })
      when credit_score >= @manual_review_credit_score do
    Logger.info(
      "[ApplicationProcessor] Evaluating secured loan #{application_id} " <>
        "for #{applicant_id} (score: #{credit_score}, employment: #{employment_status})"
    )

    dti = calculate_dti(requested_amount, annual_income)

    with {:ok, bureau_data} <- CreditBureau.pull_full_report(applicant_id),
         {:ok, offer} <- LoanOfferBuilder.build(:secured_loan, requested_amount, credit_score, bureau_data),
         {:ok, _} <- ApplicationRepo.update_status(application_id, :conditionally_approved, %{
                       offer_id: offer.id,
                       dti: dti
                     }),
         :ok <- ApplicantMailer.send_conditional_approval(applicant_id, offer),
         :ok <- AuditLog.write(:application_conditionally_approved, applicant_id, %{
                  application_id: application_id,
                  product: :secured_loan,
                  amount: requested_amount,
                  dti: dti
                }) do
      {:ok, :conditionally_approved, offer}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def evaluate(%Lending.Application{
        application_id: application_id,
        applicant_id: applicant_id,
        requested_amount: _requested_amount,
        annual_income: _annual_income,
        employment_status: _employment_status,
        product_type: product_type,
        credit_score: credit_score
      })
      when credit_score < @manual_review_credit_score do
    Logger.info(
      "[ApplicationProcessor] Rejecting #{product_type} application #{application_id} " <>
        "for #{applicant_id} due to insufficient credit score (#{credit_score})"
    )

    with {:ok, _} <- ApplicationRepo.update_status(application_id, :rejected, %{reason: :credit_score}),
         :ok <- ApplicantMailer.send_rejection(applicant_id, application_id, :credit_score),
         :ok <- AuditLog.write(:application_rejected, applicant_id, %{
                  application_id: application_id,
                  product: product_type,
                  credit_score: credit_score
                }) do
      {:error, :rejected_low_credit}
    end
  end
  # VALIDATION: SMELL END

  def evaluate(%Lending.Application{application_id: id, product_type: pt}) do
    Logger.error("[ApplicationProcessor] No evaluation rule for product '#{pt}' on #{id}")
    {:error, :unsupported_product}
  end

  defp calculate_dti(requested_amount, annual_income) do
    monthly_payment = requested_amount / 60
    monthly_income = annual_income / 12
    Float.round(monthly_payment / monthly_income, 4)
  end
end
```
