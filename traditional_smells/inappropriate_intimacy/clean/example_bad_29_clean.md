```elixir
defmodule MyApp.Healthcare.ClaimSubmitter do
  @moduledoc """
  Prepares and submits insurance claims on behalf of patients
  following a completed clinical encounter.
  Validates payer compatibility and coverage eligibility before transmission.
  """

  alias MyApp.Healthcare.{PatientPolicy, CareProvider, Encounter, ClaimRecord}
  alias MyApp.Healthcare.Payers.EDITransmitter
  alias MyApp.Notifications.ClaimMailer

  @claim_submission_timeout_ms 10_000

  def submit(encounter_id, policy_id) do
    with {:ok, encounter} <- Encounter.fetch(encounter_id),
         {:ok, policy}    <- PatientPolicy.fetch(policy_id),
         {:ok, provider}  <- CareProvider.fetch(encounter.provider_id) do

      payer_id             = policy.payer_id
      group_number         = policy.group_number
      coverage_type        = policy.coverage_type
      deductible_remaining = policy.deductible_remaining

      npi_number      = provider.npi_number
      accepted_payers = provider.accepted_payers
      billing_codes   = provider.billing_codes

      cond do
        payer_id not in accepted_payers ->
          {:error, :payer_not_accepted_by_provider}

        coverage_type not in [:hmo, :ppo, :epo, :pos] ->
          {:error, :unsupported_coverage_type}

        not codes_covered?(encounter.procedure_codes, billing_codes) ->
          {:error, :procedure_not_billable}

        true ->
          payload = build_edi_payload(
            encounter, npi_number, payer_id,
            group_number, coverage_type, deductible_remaining
          )
          transmit_claim(payload, encounter, policy, provider)
      end
    end
  end

  def check_status(claim_id) do
    case ClaimRecord.fetch(claim_id) do
      nil   -> {:error, :not_found}
      claim -> EDITransmitter.query_status(claim.payer_id, claim.submission_reference)
    end
  end

  def void(claim_id, reason) do
    case ClaimRecord.fetch(claim_id) do
      nil -> {:error, :not_found}
      %{status: :paid} -> {:error, :cannot_void_paid_claim}
      claim ->
        case EDITransmitter.void(claim.payer_id, claim.submission_reference) do
          :ok ->
            updated = %{claim | status: :voided, void_reason: reason, voided_at: DateTime.utc_now()}
            ClaimRecord.save(updated)
            {:ok, updated}
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def list_for_patient(patient_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    :ets.tab2list(:claim_records)
    |> Enum.map(fn {_, c} -> c end)
    |> Enum.filter(&(&1.patient_id == patient_id))
    |> then(fn claims ->
      if status, do: Enum.filter(claims, &(&1.status == status)), else: claims
    end)
    |> Enum.sort_by(& &1.submitted_at, {:desc, DateTime})
  end


  defp codes_covered?(procedure_codes, billing_codes) do
    Enum.all?(procedure_codes, &(&1 in billing_codes))
  end

  defp build_edi_payload(encounter, npi, payer_id, group_number, coverage_type, deductible) do
    %{
      transaction_set:   "837P",
      npi:               npi,
      payer_id:          payer_id,
      group_number:      group_number,
      coverage_type:     coverage_type,
      deductible_credit: deductible,
      patient_id:        encounter.patient_id,
      service_date:      encounter.service_date,
      procedure_codes:   encounter.procedure_codes,
      diagnosis_codes:   encounter.diagnosis_codes,
      total_charge:      encounter.total_charge
    }
  end

  defp transmit_claim(payload, encounter, policy, provider) do
    task = Task.async(fn ->
      EDITransmitter.send(payload)
    end)

    case Task.await(task, @claim_submission_timeout_ms) do
      {:ok, reference} ->
        record = %{
          id:                   generate_id(),
          encounter_id:         encounter.id,
          patient_id:           encounter.patient_id,
          provider_id:          provider.id,
          policy_id:            policy.id,
          payer_id:             payload.payer_id,
          submission_reference: reference,
          total_charge:         encounter.total_charge,
          status:               :submitted,
          submitted_at:         DateTime.utc_now()
        }
        ClaimRecord.save(record)
        ClaimMailer.deliver_confirmation(record)
        {:ok, record}

      {:error, reason} ->
        {:error, {:transmission_failed, reason}}
    end
  end

  defp generate_id do
    "CLM-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
