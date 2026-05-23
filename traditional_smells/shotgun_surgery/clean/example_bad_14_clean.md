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

  def get_processing_sla_days(:auto),   do: 30
  def get_processing_sla_days(:home),   do: 45
  def get_processing_sla_days(:health), do: 15
  def get_processing_sla_days(_),       do: 30

  def assign_adjuster_tier(:auto),   do: :field_adjuster
  def assign_adjuster_tier(:home),   do: :property_specialist
  def assign_adjuster_tier(:health), do: :medical_reviewer
  def assign_adjuster_tier(_),       do: :general_adjuster

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
