# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Insurance.ClaimProcessor.adjudicate/2`
- **Affected function(s):** `adjudicate/2`
- **Short explanation:** `adjudicate/2` handles policy retrieval, coverage eligibility, duplicate-claim detection, damage assessment, deductible application, reserve posting, payment disbursement, fraud-flag checking, document generation, and claimant notification in one monolithic function.

---

```elixir
defmodule Insurance.ClaimProcessor do
  @moduledoc """
  Adjudicates insurance claims by verifying coverage,
  calculating payouts, and initiating disbursements.
  """

  require Logger

  alias Insurance.{
    Claim, Policy, CoverageChecker, FraudDetector,
    Reserve, DisbursementService, Document, Mailer
  }

  @auto_approve_limit_cents 50_000
  @fraud_review_score       0.70

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `adjudicate/2` concatenates policy
  # lookup, coverage-eligibility verification, open-claim deduplication,
  # damage-amount calculation, deductible subtraction, fraud scoring,
  # reserve creation, auto vs manual approval routing, payment initiation,
  # document generation, and claimant email notification into one function
  # body exceeding 110 lines without delegating to any focused helpers.
  def adjudicate(%Claim{} = claim, opts \\ []) do
    adjuster = Keyword.get(opts, :adjuster, "auto_system")

    Logger.info("Adjudicating claim #{claim.id} by #{adjuster}")

    # 1. Load the associated policy
    case Policy.get(claim.policy_id) do
      nil ->
        {:error, :policy_not_found}

      %Policy{status: status} when status in [:cancelled, :lapsed] ->
        {:error, :policy_not_active}

      %Policy{} = policy ->
        # 2. Check that the incident date falls within the coverage period
        incident_date = DateTime.to_date(claim.incident_at)

        coverage_active =
          Date.compare(incident_date, policy.effective_date) != :lt and
            Date.compare(incident_date, policy.expiry_date) != :gt

        unless coverage_active do
          {:error, :outside_coverage_period}
        else
          # 3. Verify the claimed peril is covered
          case CoverageChecker.check(policy, claim.peril_type) do
            {:error, :not_covered} ->
              {:error, {:peril_not_covered, claim.peril_type}}

            {:ok, coverage} ->
              # 4. Detect duplicate open claims for the same incident
              existing_open =
                Claim.list_open_for_policy(policy.id)
                |> Enum.filter(&(&1.incident_at == claim.incident_at and &1.id != claim.id))

              if existing_open != [] do
                Logger.warning("Possible duplicate claim #{claim.id} for policy #{policy.id}")
                {:error, {:duplicate_claim, Enum.map(existing_open, & &1.id)}}
              else
                # 5. Compute the claimable amount
                raw_damage = min(claim.claimed_amount_cents, coverage.limit_cents)

                deductible = coverage.deductible_cents

                payout_before_fraud =
                  if raw_damage > deductible,
                    do:   raw_damage - deductible,
                    else: 0

                if payout_before_fraud == 0 do
                  Claim.update(claim.id, %{status: :closed_below_deductible})
                  {:ok, %{claim: claim, payout: 0, reason: :below_deductible}}
                else
                  # 6. Fraud scoring
                  fraud_result =
                    FraudDetector.score(%{
                      policy_id:     policy.id,
                      claimant_id:   claim.claimant_id,
                      amount_cents:  payout_before_fraud,
                      peril_type:    claim.peril_type,
                      incident_date: incident_date
                    })

                  {payout_cents, fraud_hold} =
                    case fraud_result do
                      {:ok, %{score: score}} when score >= @fraud_review_score ->
                        Logger.warning("Fraud score #{score} — holding claim #{claim.id}")
                        {payout_before_fraud, true}

                      _ ->
                        {payout_before_fraud, false}
                    end

                  # 7. Create reserve entry
                  case Reserve.post(%{
                    policy_id:    policy.id,
                    claim_id:     claim.id,
                    amount_cents: payout_cents,
                    created_by:   adjuster,
                    posted_at:    DateTime.utc_now()
                  }) do
                    {:error, reason} ->
                      Logger.error("Reserve post failed: #{inspect(reason)}")
                      {:error, :reserve_failed}

                    {:ok, _reserve} ->
                      # 8. Determine approval path
                      {new_status, disbursement_result} =
                        cond do
                          fraud_hold ->
                            {:fraud_review, nil}

                          payout_cents <= @auto_approve_limit_cents ->
                            result = DisbursementService.initiate(%{
                              claim_id:      claim.id,
                              payee_id:      claim.claimant_id,
                              amount_cents:  payout_cents,
                              method:        policy.preferred_payment_method
                            })
                            {:approved, result}

                          true ->
                            {:pending_manual_review, nil}
                        end

                      Claim.update(claim.id, %{
                        status:       new_status,
                        payout_cents: payout_cents,
                        adjudicated_by:  adjuster,
                        adjudicated_at:  DateTime.utc_now()
                      })

                      # 9. Generate settlement document
                      unless new_status == :fraud_review do
                        Document.generate(:settlement_letter, %{
                          claim:   claim,
                          policy:  policy,
                          payout:  payout_cents,
                          status:  new_status
                        })
                      end

                      # 10. Notify claimant
                      status_message =
                        case new_status do
                          :approved             -> "Your claim has been approved and payment is being processed."
                          :pending_manual_review -> "Your claim requires additional review. We will contact you within 5 business days."
                          :fraud_review         -> "Your claim is under review. A specialist will contact you shortly."
                          _                     -> "Your claim status has been updated."
                        end

                      email_body = """
                      Dear #{claim.claimant_name},

                      Claim Reference : #{claim.reference_number}
                      Status          : #{new_status}
                      Approved Amount : $#{Float.round(payout_cents / 100, 2)}

                      #{status_message}

                      Thank you for being a valued policyholder.
                      """

                      case Mailer.send_email(claim.claimant_email, "Claim Update: #{claim.reference_number}", email_body) do
                        {:ok, _}         -> :ok
                        {:error, reason} -> Logger.warning("Claimant email failed: #{inspect(reason)}")
                      end

                      {:ok, %{claim_id: claim.id, status: new_status, payout_cents: payout_cents,
                               disbursement: disbursement_result}}
                  end
                end
              end
          end
        end
    end
  end
  # VALIDATION: SMELL END
end
```
