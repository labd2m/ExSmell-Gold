# Annotated Example 48 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `process_loan_application/2`, inside the `with` expression's `else` block
- **Affected function(s):** `process_loan_application/2`
- **Short explanation:** Five loan processing steps each produce structurally different error shapes. Consolidating all into one `else` block makes it impossible to tell which pipeline step originated a given error pattern without tracing back through every clause.

---

```elixir
defmodule Lending.LoanApplicationProcessor do
  @moduledoc """
  Processes consumer loan applications end-to-end:
  applicant resolution, creditworthiness assessment, product matching,
  underwriting decision, and application record creation.
  """

  alias Lending.{
    ApplicantRepo,
    CreditBureau,
    ProductMatcher,
    UnderwritingEngine,
    ApplicationRepo
  }

  require Logger

  @minimum_credit_score 580
  @supported_purposes ~w(home_improvement debt_consolidation auto education personal)a

  @doc """
  Processes a loan application for `applicant_id` with the given `application_params`.

  Expected params: `:amount_cents`, `:term_months`, `:purpose`, `:declared_income_cents`.

  Returns `{:ok, application}` or a structured error.
  """
  @spec process_loan_application(String.t(), map()) ::
          {:ok, map()}
          | {:error, :applicant_not_found}
          | {:error, :credit_pull_failed}
          | {:error, :no_matching_product}
          | {:error, :underwriting_declined, String.t()}
          | {:error, :application_save_failed}
  def process_loan_application(applicant_id, application_params) do
    unless application_params.purpose in @supported_purposes do
      {:error, :no_matching_product}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because five with-clauses each fail with a
      # distinct error shape ({:error, :not_found}, {:error, :bureau, _},
      # {:error, :no_product}, {:declined, _, _}, {:error, changeset}).
      # All are collapsed into one else block, making it impossible to
      # attribute a given pattern to the step that produced it without
      # cross-referencing every clause.
      with {:ok, applicant}   <- ApplicantRepo.fetch(applicant_id),
           {:ok, credit}      <- CreditBureau.pull_report(applicant.ssn_token),
           {:ok, product}     <- ProductMatcher.match(%{
                                   amount_cents:          application_params.amount_cents,
                                   term_months:           application_params.term_months,
                                   credit_score:          credit.score,
                                   purpose:               application_params.purpose
                                 }),
           {:ok, decision}    <- UnderwritingEngine.evaluate(%{
                                   applicant:             applicant,
                                   credit:                credit,
                                   product:               product,
                                   declared_income_cents: application_params.declared_income_cents
                                 }),
           {:ok, application} <- ApplicationRepo.insert(%{
                                   applicant_id:     applicant_id,
                                   product_id:       product.id,
                                   amount_cents:     application_params.amount_cents,
                                   term_months:      application_params.term_months,
                                   apr:              decision.apr,
                                   status:           :approved,
                                   decided_at:       DateTime.utc_now()
                                 }) do
        Logger.info("Loan application #{application.id} approved for applicant #{applicant_id}")
        {:ok, application}
      else
        {:error, :not_found} ->
          Logger.warn("Applicant #{applicant_id} not found")
          {:error, :applicant_not_found}

        {:error, :bureau, reason} ->
          Logger.error("Credit bureau pull failed: #{inspect(reason)}")
          {:error, :credit_pull_failed}

        {:error, :no_product} ->
          Logger.info("No matching loan product for applicant #{applicant_id}")
          {:error, :no_matching_product}

        {:declined, code, explanation} ->
          Logger.info("Underwriting declined #{applicant_id}: [#{code}] #{explanation}")
          {:error, :underwriting_declined, explanation}

        {:error, %Ecto.Changeset{} = cs} ->
          Logger.error("Application insert failed: #{inspect(cs.errors)}")
          {:error, :application_save_failed}
      end
      # VALIDATION: SMELL END
    end
  end
end
```
