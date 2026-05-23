# Example Bad 14 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_deductible/1`, `get_processing_sla_days/1`, `assign_adjuster_tier/1`, and `required_documents/1` inside `Insurance.ClaimProcessor`
- **Affected Functions**: `calculate_deductible/1`, `get_processing_sla_days/1`, `assign_adjuster_tier/1`, `required_documents/1`
- **Explanation**: The insurance claim type logic (`:auto`, `:home`, `:health`) is distributed across four separate functions. Adding a new claim type (e.g., `:life`) forces four independent edits scattered around the module, a clear case of Shotgun Surgery.

```elixir
defmodule Insurance.ClaimProcessor do
  @moduledoc """
  Manages the lifecycle of insurance claims including deductible computation,
  SLA-based processing scheduling, adjuster tier assignment, and required
  document validation for multiple types of insurance claims.
  """

  alias Insurance.{
    Claim, Policy, AdjusterPool,
    DocumentStore, SLATracker, ClaimLedger, CustomerPortal
  }

  def submit_claim(policy_id, claim_type, incident_details) do
    with {:ok, policy}  <- Policy.fetch(policy_id),
         :ok            <- validate_policy_coverage(policy, claim_type),
         {:ok, claim}   <- create_claim(policy, claim_type, incident_details),
         {:ok, adj}     <- assign_adjuster(claim),
         :ok            <- SLATracker.register(claim, get_processing_sla_days(claim_type)),
         :ok            <- CustomerPortal.notify_submitted(policy.holder_id, claim) do
      {:ok, claim}
    end
  end

  defp create_claim(policy, claim_type, incident_details) do
    deductible = calculate_deductible(policy)
    docs       = required_documents(claim_type)

    claim = %Claim{
      policy_id:           policy.id,
      claim_type:          claim_type,
      incident_details:    incident_details,
      deductible:          deductible,
      required_documents:  docs,
      pending_documents:   docs,
      status:              :submitted,
      submitted_at:        DateTime.utc_now()
    }

    ClaimLedger.insert(claim)
  end

  defp assign_adjuster(claim) do
    tier = assign_adjuster_tier(claim.claim_type)
    AdjusterPool.assign(claim.id, tier: tier)
  end

  defp validate_policy_coverage(policy, claim_type) do
    if claim_type in policy.covered_types do
      :ok
    else
      {:error, :claim_type_not_covered}
    end
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new claim type (e.g., :life)
  # requires a new clause here AND in get_processing_sla_days/1, assign_adjuster_tier/1,
  # and required_documents/1 — four scattered changes for one new claim type.
  def calculate_deductible(%Policy{type: :auto, deductible_pct: pct, coverage_limit: limit}) do
    Float.round(limit * pct, 2)
  end

  def calculate_deductible(%Policy{type: :home, deductible_pct: pct, coverage_limit: limit}) do
    Float.round(limit * pct * 1.1, 2)
  end

  def calculate_deductible(%Policy{type: :health, annual_deductible: deductible}) do
    deductible
  end

  def calculate_deductible(%Policy{deductible_pct: pct, coverage_limit: limit}) do
    Float.round(limit * pct, 2)
  end
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new claim type also requires a new SLA days
  # clause here, independent of the change in calculate_deductible/1.
  def get_processing_sla_days(:auto),   do: 30
  def get_processing_sla_days(:home),   do: 45
  def get_processing_sla_days(:health), do: 15
  def get_processing_sla_days(_),       do: 30
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new claim type also requires a new adjuster
  # tier clause here, independent of the previous two locations.
  def assign_adjuster_tier(:auto),   do: :field_adjuster
  def assign_adjuster_tier(:home),   do: :property_specialist
  def assign_adjuster_tier(:health), do: :medical_reviewer
  def assign_adjuster_tier(_),       do: :general_adjuster
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new claim type also requires a new required
  # documents clause here, completing the four-location change.
  def required_documents(:auto) do
    [:police_report, :photos_of_damage, :repair_estimate, :drivers_license]
  end

  def required_documents(:home) do
    [:photos_of_damage, :repair_estimate, :property_deed, :incident_report]
  end

  def required_documents(:health) do
    [:medical_records, :diagnosis_report, :itemized_bill, :doctors_referral]
  end

  def required_documents(_) do
    [:incident_report, :supporting_evidence]
  end
  # VALIDATION: SMELL END [location 4 of 4]

  def receive_document(%Claim{} = claim, doc_type, doc_content) do
    with :ok <- DocumentStore.save(claim.id, doc_type, doc_content) do
      updated = %{claim |
        pending_documents: List.delete(claim.pending_documents, doc_type)
      }

      if updated.pending_documents == [] do
        ClaimLedger.update_status(claim.id, :documents_complete)
      end

      ClaimLedger.update(updated)
    end
  end

  def approve_claim(%Claim{status: :under_review} = claim, payout_amount) do
    with {:ok, updated} <- ClaimLedger.update_status(claim.id, :approved) do
      ClaimLedger.record_payout(updated, payout_amount)
      CustomerPortal.notify_approved(updated.policy.holder_id, updated, payout_amount)
      {:ok, updated}
    end
  end

  def approve_claim(%Claim{status: status}, _payout) do
    {:error, {:cannot_approve, status}}
  end
end
```
