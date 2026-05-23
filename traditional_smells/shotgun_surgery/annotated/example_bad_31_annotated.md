## Smell Metadata

- **Smell:** Shotgun Surgery
- **Expected Smell Location:** Functions `copay_amount/2`, `deductible/1`, `covers_specialist?/1` in `Healthcare.BenefitsCalculator`; `prior_auth_required?/2` in `Healthcare.AuthorizationGateway`; `reimbursement_rate/1`, `submission_format/1` in `Healthcare.ClaimsProcessor`
- **Affected Functions:** See above (6 functions across 3 modules)
- **Explanation:** Adding a new insurance plan type (e.g., `:hdhp`) requires scattered changes across three separate healthcare modules. Benefit amounts, authorization rules, and claims submission formats are each independently pattern-matched per plan type, so every module needs its own independent update.

```elixir
defmodule Healthcare.BenefitsCalculator do
  @moduledoc """
  Computes patient cost-sharing amounts such as copays and deductibles
  for covered services, based on the member's insurance plan type.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: This is a smell because adding a new insurance plan (e.g., :hdhp)
  # VALIDATION: requires new clauses in copay_amount/2, deductible/1, and
  # VALIDATION: covers_specialist?/1 here, AND independent changes in
  # VALIDATION: AuthorizationGateway and ClaimsProcessor.

  @spec copay_amount(atom(), atom()) :: float()
  def copay_amount(:hmo, :primary_care),   do: 20.0
  def copay_amount(:hmo, :specialist),     do: 50.0
  def copay_amount(:hmo, :emergency),      do: 150.0

  def copay_amount(:ppo, :primary_care),   do: 30.0
  def copay_amount(:ppo, :specialist),     do: 60.0
  def copay_amount(:ppo, :emergency),      do: 200.0

  def copay_amount(:epo, :primary_care),   do: 25.0
  def copay_amount(:epo, :specialist),     do: 55.0
  def copay_amount(:epo, :emergency),      do: 175.0

  def copay_amount(_, _), do: 0.0

  @spec deductible(atom()) :: float()
  def deductible(:hmo), do: 500.0
  def deductible(:ppo), do: 1_000.0
  def deductible(:epo), do: 750.0

  @spec covers_specialist?(atom()) :: boolean()
  def covers_specialist?(:hmo), do: true
  def covers_specialist?(:ppo), do: true
  def covers_specialist?(:epo), do: true

  # VALIDATION: SMELL END

  def patient_responsibility(plan, service_type, billed_amount, ytd_deductible_met) do
    deductible_remaining = max(deductible(plan) - ytd_deductible_met, 0.0)
    deductible_applied   = min(billed_amount, deductible_remaining)
    after_deductible     = billed_amount - deductible_applied

    copay  = copay_amount(plan, service_type)
    oop    = deductible_applied + copay

    %{
      deductible_applied: Float.round(deductible_applied, 2),
      copay:              Float.round(copay, 2),
      total_oop:          Float.round(oop, 2),
      plan_pays:          Float.round(after_deductible - copay, 2)
    }
  end
end

defmodule Healthcare.AuthorizationGateway do
  @moduledoc """
  Determines whether a proposed service requires prior authorization
  based on plan type and procedure category.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: prior_auth_required?/2 requires independent updates per plan type,
  # VALIDATION: completely separate from BenefitsCalculator and ClaimsProcessor.

  @spec prior_auth_required?(atom(), atom()) :: boolean()
  def prior_auth_required?(:hmo, :specialist),     do: true
  def prior_auth_required?(:hmo, :imaging),        do: true
  def prior_auth_required?(:hmo, :surgery),        do: true
  def prior_auth_required?(:hmo, _),               do: false

  def prior_auth_required?(:ppo, :surgery),        do: true
  def prior_auth_required?(:ppo, _),               do: false

  def prior_auth_required?(:epo, :specialist),     do: true
  def prior_auth_required?(:epo, :imaging),        do: true
  def prior_auth_required?(:epo, _),               do: false

  # VALIDATION: SMELL END

  def authorize_service(member, service_type, provider) do
    plan = member.insurance_plan

    if prior_auth_required?(plan, service_type) do
      submit_auth_request(member.member_id, service_type, provider)
    else
      {:ok, :not_required}
    end
  end

  defp submit_auth_request(member_id, service_type, provider) do
    {:ok, %{auth_number: "AUTH-#{:rand.uniform(999_999)}", member: member_id,
            service: service_type, provider: provider.npi}}
  end
end

defmodule Healthcare.ClaimsProcessor do
  @moduledoc """
  Handles electronic claims submission and reimbursement rate calculation
  for services rendered to members of supported insurance plans.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: reimbursement_rate/1 and submission_format/1 are yet more scattered
  # VALIDATION: change points that each require updates when a new plan type is added.

  @spec reimbursement_rate(atom()) :: float()
  def reimbursement_rate(:hmo), do: 0.80
  def reimbursement_rate(:ppo), do: 0.70
  def reimbursement_rate(:epo), do: 0.75

  @spec submission_format(atom()) :: atom()
  def submission_format(:hmo), do: :edi_837p
  def submission_format(:ppo), do: :edi_837p
  def submission_format(:epo), do: :edi_837i

  # VALIDATION: SMELL END

  def process_claim(claim) do
    plan   = claim.member.insurance_plan
    rate   = reimbursement_rate(plan)
    format = submission_format(plan)

    approved_amount = claim.billed_amount * rate

    %{
      claim_id:        claim.id,
      member_id:       claim.member.member_id,
      billed:          claim.billed_amount,
      approved:        Float.round(approved_amount, 2),
      format:          format,
      submitted_at:    DateTime.utc_now(),
      expected_payment: Float.round(approved_amount, 2)
    }
  end
end
```
