```elixir
defmodule Pharmacy.PrescriptionValidator do
  @moduledoc """
  Validates incoming electronic prescriptions against drug scheduling
  rules, supply limits, prescriber authority, and patient eligibility.
  Integrates with the state PDMP and formulary services.
  """

  require Logger

  alias Pharmacy.{
    PDMP,
    FormularyChecker,
    PrescriberRegistry,
    PatientProfile,
    PrescriptionRepo,
    AuditLog,
    PharmacistAlerts
  }

  @schedule_ii_max_days 30
  @schedule_iii_max_days 90
  @standard_max_days 365

  # `prescriber_id`, `drug_name`, and `quantity` are extracted in every clause
  # head even though they play no part in guard evaluation or clause selection.
  # Only `drug_schedule` selects the clause, and `days_supply` is evaluated in
  # the guards. With three clauses and seven per-clause bindings, the reader
  # must parse every field to discover that only two of them control dispatch.
  def validate(%Pharmacy.Prescription{
        prescription_id: prescription_id,
        patient_id: patient_id,
        prescriber_id: prescriber_id,
        drug_name: drug_name,
        quantity: quantity,
        drug_schedule: :schedule_ii,
        days_supply: days_supply
      })
      when days_supply <= @schedule_ii_max_days do
    Logger.info(
      "[PrescriptionValidator] Validating Schedule II prescription #{prescription_id} " <>
        "for patient #{patient_id}: #{drug_name} x#{quantity}"
    )

    with {:ok, prescriber} <- PrescriberRegistry.fetch(prescriber_id),
         :ok <- assert_schedule_ii_authority(prescriber),
         {:ok, _report} <- PDMP.submit_and_check(patient_id, drug_name, quantity, days_supply),
         {:ok, _} <- FormularyChecker.verify(:schedule_ii, drug_name, quantity),
         {:ok, patient} <- PatientProfile.fetch(patient_id),
         :ok <- check_patient_eligibility(patient, drug_name),
         :ok <- PrescriptionRepo.mark_validated(prescription_id, :schedule_ii),
         :ok <- AuditLog.write(:prescription_validated, prescriber_id, %{
                  prescription_id: prescription_id,
                  patient_id: patient_id,
                  drug_name: drug_name,
                  schedule: :schedule_ii,
                  quantity: quantity,
                  days_supply: days_supply
                }) do
      {:ok, :validated, prescription_id}
    else
      {:error, :no_schedule_ii_authority} ->
        Logger.warning(
          "[PrescriptionValidator] Prescriber #{prescriber_id} lacks Schedule II authority"
        )

        PharmacistAlerts.flag(prescription_id, :unauthorized_prescriber)
        {:error, :prescriber_not_authorized}

      {:error, :pdmp_flag} ->
        Logger.warning("[PrescriptionValidator] PDMP flag on patient #{patient_id} for #{drug_name}")
        PharmacistAlerts.flag(prescription_id, :pdmp_concern)
        {:error, :pdmp_flagged}

      {:error, reason} ->
        Logger.error("[PrescriptionValidator] Validation failed for #{prescription_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def validate(%Pharmacy.Prescription{
        prescription_id: prescription_id,
        patient_id: patient_id,
        prescriber_id: prescriber_id,
        drug_name: drug_name,
        quantity: quantity,
        drug_schedule: :schedule_ii,
        days_supply: days_supply
      })
      when days_supply > @schedule_ii_max_days do
    Logger.warning(
      "[PrescriptionValidator] Schedule II prescription #{prescription_id} exceeds " <>
        "#{@schedule_ii_max_days}-day supply limit (requested: #{days_supply} days)"
    )

    PharmacistAlerts.flag(prescription_id, :supply_limit_exceeded)

    AuditLog.write(:prescription_rejected, prescriber_id, %{
      prescription_id: prescription_id,
      patient_id: patient_id,
      drug_name: drug_name,
      quantity: quantity,
      days_supply: days_supply,
      reason: :exceeds_schedule_ii_limit
    })

    {:error, :supply_limit_exceeded}
  end

  def validate(%Pharmacy.Prescription{
        prescription_id: prescription_id,
        patient_id: patient_id,
        prescriber_id: prescriber_id,
        drug_name: drug_name,
        quantity: quantity,
        drug_schedule: :schedule_iii_iv,
        days_supply: days_supply
      })
      when days_supply <= @schedule_iii_max_days do
    Logger.info(
      "[PrescriptionValidator] Validating Schedule III/IV prescription #{prescription_id} " <>
        "for patient #{patient_id}: #{drug_name} x#{quantity}, #{days_supply} days"
    )

    with {:ok, _prescriber} <- PrescriberRegistry.fetch(prescriber_id),
         {:ok, _} <- FormularyChecker.verify(:schedule_iii_iv, drug_name, quantity),
         {:ok, patient} <- PatientProfile.fetch(patient_id),
         :ok <- check_patient_eligibility(patient, drug_name),
         :ok <- PrescriptionRepo.mark_validated(prescription_id, :schedule_iii_iv),
         :ok <- AuditLog.write(:prescription_validated, prescriber_id, %{
                  prescription_id: prescription_id,
                  patient_id: patient_id,
                  drug_name: drug_name,
                  schedule: :schedule_iii_iv,
                  quantity: quantity
                }) do
      {:ok, :validated, prescription_id}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate(%Pharmacy.Prescription{prescription_id: id, drug_schedule: sched, days_supply: ds})
      when ds > @schedule_iii_max_days do
    Logger.warning("[PrescriptionValidator] Supply #{ds} days exceeds limit for #{sched} on #{id}")
    {:error, :supply_limit_exceeded}
  end

  def validate(%Pharmacy.Prescription{prescription_id: id, drug_schedule: unknown_schedule}) do
    Logger.error("[PrescriptionValidator] Unknown drug schedule '#{unknown_schedule}' on #{id}")
    {:error, :unknown_schedule}
  end

  defp assert_schedule_ii_authority(%{dea_schedule_ii: true}), do: :ok
  defp assert_schedule_ii_authority(_), do: {:error, :no_schedule_ii_authority}

  defp check_patient_eligibility(%{allergies: allergies, contraindications: contra}, drug_name) do
    cond do
      drug_name in allergies -> {:error, :patient_allergy}
      drug_name in contra -> {:error, :contraindicated}
      true -> :ok
    end
  end
end
```
