# Annotated Example 26

- **Smell name:** Complex Branching
- **Expected smell location:** `submit_claim/2` function, the `case` expression over the insurance provider API response
- **Affected function(s):** `submit_claim/2`
- **Short explanation:** All possible response variants from a single insurance claims API endpoint — approved, partially approved, pending review, rejected for multiple distinct reasons, duplicate detection, provider errors, and network failures — are handled inside one large `case` expression in a single function, inflating cyclomatic complexity and making isolated testing of each scenario impractical.

```elixir
defmodule Insurance.ClaimsSubmission do
  @moduledoc """
  Submits insurance claims to the InsureNet provider API on behalf of policyholders.
  Handles medical, dental, and vision claim types with automatic adjudication tracking.
  """

  require Logger

  alias Insurance.Repo
  alias Insurance.Schema.{Claim, Policy, ClaimAuditLog}
  alias Insurance.InsureNet.Client
  alias Insurance.Notifications

  @claim_types [:medical, :dental, :vision, :pharmacy]
  @max_claim_amount_cents 10_000_000

  def submit(policy_id, claim_params, claim_type \\ :medical)
      when claim_type in @claim_types do
    with {:ok, policy} <- fetch_policy(policy_id),
         :ok <- check_policy_active(policy),
         :ok <- validate_claim_amount(claim_params),
         :ok <- check_coverage(policy, claim_type),
         {:ok, payload} <- build_claim_payload(policy, claim_params, claim_type) do
      submit_claim(policy, Client.post("/claims", payload))
    end
  end

  defp fetch_policy(id) do
    case Repo.get(Policy, id) do
      nil -> {:error, :policy_not_found}
      policy -> {:ok, policy}
    end
  end

  defp check_policy_active(%Policy{status: :active}), do: :ok
  defp check_policy_active(%Policy{status: :expired}), do: {:error, :policy_expired}
  defp check_policy_active(%Policy{status: :suspended}), do: {:error, :policy_suspended}
  defp check_policy_active(_), do: {:error, :policy_inactive}

  defp validate_claim_amount(%{amount_cents: amount}) when amount > @max_claim_amount_cents,
    do: {:error, :claim_amount_exceeds_limit}

  defp validate_claim_amount(%{amount_cents: amount}) when amount <= 0,
    do: {:error, :invalid_claim_amount}

  defp validate_claim_amount(_), do: :ok

  defp check_coverage(%Policy{covered_types: covered}, claim_type) do
    if claim_type in covered, do: :ok, else: {:error, :claim_type_not_covered}
  end

  defp build_claim_payload(policy, params, type) do
    {:ok,
     %{
       policy_number: policy.policy_number,
       claim_type: type,
       provider_code: params[:provider_code],
       service_date: params[:service_date],
       amount_cents: params[:amount_cents],
       diagnosis_codes: params[:diagnosis_codes] || [],
       procedure_codes: params[:procedure_codes] || []
     }}
  end

  # VALIDATION: SMELL START - Complex Branching
  # VALIDATION: This is a smell because the function takes on full responsibility
  # for interpreting every possible response from the InsureNet claims endpoint
  # inside a single case expression with many arms. Approval, partial approval,
  # pending adjudication, multiple rejection reasons, duplicate detection, and
  # infrastructure failures are each a separate concern but are all collapsed
  # into one function body, raising cyclomatic complexity significantly and
  # making each branch impossible to test without exercising the entire function.
  defp submit_claim(policy, provider_response) do
    case provider_response do
      {:ok, %{status: 200, body: %{"claim_id" => cid, "status" => "approved", "approved_amount_cents" => approved}}} ->
        Logger.info("Claim #{cid} approved for policy #{policy.id}, approved amount: #{approved}")

        {:ok, claim} =
          Repo.insert(%Claim{
            policy_id: policy.id,
            claim_id: cid,
            status: :approved,
            approved_amount_cents: approved
          })

        Repo.insert(%ClaimAuditLog{claim_id: claim.id, event: :approved})
        Notifications.send_claim_approved(policy, claim)
        {:ok, claim}

      {:ok, %{status: 200, body: %{"claim_id" => cid, "status" => "partially_approved", "approved_amount_cents" => approved, "reason" => reason}}} ->
        Logger.info("Claim #{cid} partially approved for policy #{policy.id}: #{approved} cents, reason: #{reason}")

        {:ok, claim} =
          Repo.insert(%Claim{
            policy_id: policy.id,
            claim_id: cid,
            status: :partially_approved,
            approved_amount_cents: approved,
            adjudication_note: reason
          })

        Notifications.send_claim_partially_approved(policy, claim)
        {:ok, claim}

      {:ok, %{status: 202, body: %{"claim_id" => cid, "status" => "pending_review", "eta_days" => eta}}} ->
        Logger.info("Claim #{cid} pending manual review for policy #{policy.id}, eta #{eta} days")

        {:ok, claim} =
          Repo.insert(%Claim{
            policy_id: policy.id,
            claim_id: cid,
            status: :pending_review
          })

        Notifications.send_claim_pending(policy, claim, eta)
        {:ok, claim}

      {:ok, %{status: 200, body: %{"claim_id" => cid, "status" => "rejected", "reason" => "not_covered"}}} ->
        Logger.warning("Claim #{cid} rejected (not covered) for policy #{policy.id}")
        Repo.insert(%Claim{policy_id: policy.id, claim_id: cid, status: :rejected, rejection_reason: "not_covered"})
        Notifications.send_claim_rejected(policy, :not_covered)
        {:error, :not_covered}

      {:ok, %{status: 200, body: %{"claim_id" => cid, "status" => "rejected", "reason" => "deductible_not_met"}}} ->
        Logger.warning("Claim #{cid} rejected (deductible not met) for policy #{policy.id}")
        Repo.insert(%Claim{policy_id: policy.id, claim_id: cid, status: :rejected, rejection_reason: "deductible_not_met"})
        Notifications.send_claim_rejected(policy, :deductible_not_met)
        {:error, :deductible_not_met}

      {:ok, %{status: 200, body: %{"claim_id" => cid, "status" => "rejected", "reason" => "pre_auth_required", "auth_ref" => ref}}} ->
        Logger.warning("Claim #{cid} rejected (pre-auth required, ref: #{ref}) for policy #{policy.id}")
        Repo.insert(%Claim{policy_id: policy.id, claim_id: cid, status: :rejected, rejection_reason: "pre_auth_required"})
        {:error, {:pre_auth_required, ref}}

      {:ok, %{status: 200, body: %{"claim_id" => cid, "status" => "rejected", "reason" => "out_of_network"}}} ->
        Logger.warning("Claim #{cid} rejected (out-of-network provider) for policy #{policy.id}")
        Repo.insert(%Claim{policy_id: policy.id, claim_id: cid, status: :rejected, rejection_reason: "out_of_network"})
        {:error, :out_of_network}

      {:ok, %{status: 409, body: %{"error" => "duplicate_claim", "original_claim_id" => orig}}} ->
        Logger.warning("Duplicate claim detected for policy #{policy.id}, original claim #{orig}")
        {:error, {:duplicate_claim, orig}}

      {:ok, %{status: 422, body: %{"error" => "invalid_diagnosis_code", "codes" => codes}}} ->
        Logger.warning("Invalid diagnosis codes #{inspect(codes)} for policy #{policy.id}")
        {:error, {:invalid_diagnosis_codes, codes}}

      {:ok, %{status: 422, body: %{"error" => "service_date_out_of_range"}}} ->
        Logger.warning("Service date out of policy range for policy #{policy.id}")
        {:error, :service_date_out_of_range}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by InsureNet for policy #{policy.id}")
        {:error, :rate_limited}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("InsureNet unavailable for policy #{policy.id}")
        {:error, :provider_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected InsureNet response #{status} for policy #{policy.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("InsureNet timeout for policy #{policy.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("InsureNet connection error for policy #{policy.id}: #{inspect(reason)}")
        {:error, {:provider_error, reason}}
    end
  end
  # VALIDATION: SMELL END

  def claim_status(claim_id) do
    case Repo.get(Claim, claim_id) do
      nil -> {:error, :claim_not_found}
      claim -> {:ok, claim}
    end
  end

  def pending_claims(policy_id) do
    Claim
    |> Claim.pending_for_policy(policy_id)
    |> Repo.all()
  end
end
```
