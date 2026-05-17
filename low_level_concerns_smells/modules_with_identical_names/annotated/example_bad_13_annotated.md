# Annotated Example 13 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `Healthcare.Patient`
- **Affected functions:** `Healthcare.Patient.admit/2` (file one) and `Healthcare.Patient.discharge/2` (file two)
- **Explanation:** `Healthcare.Patient` exists in both `lib/healthcare/patient.ex` and `lib/healthcare/patient_discharge.ex`. Only one can be loaded in BEAM at a time. Whichever file compiles last replaces the other, silently hiding either admission or discharge functionality — a potentially dangerous gap in a clinical system.

---

```elixir
# ── file: lib/healthcare/patient.ex ──────────────────────────────────────────

defmodule Healthcare.Patient do
  @moduledoc """
  Manages patient admission to care units. Validates insurance, checks
  bed availability, and initialises the patient's clinical record.
  """

  alias Healthcare.{
    InsuranceVerifier,
    BedManagement,
    ClinicalRecord,
    CareTeamAssigner,
    Notifier,
    Repo
  }

  @type t :: %__MODULE__{
          id: String.t(),
          mrn: String.t(),
          first_name: String.t(),
          last_name: String.t(),
          date_of_birth: Date.t(),
          gender: String.t(),
          insurance_id: String.t() | nil,
          primary_diagnosis: String.t() | nil,
          admission_type: :emergency | :elective | :observation,
          ward_id: String.t() | nil,
          bed_id: String.t() | nil,
          care_team_ids: [String.t()],
          admitted_at: DateTime.t() | nil,
          status: :pre_admission | :admitted | :discharged | :transferred
        }

  defstruct [
    :id,
    :mrn,
    :first_name,
    :last_name,
    :date_of_birth,
    :gender,
    :insurance_id,
    :primary_diagnosis,
    :admission_type,
    :ward_id,
    :bed_id,
    :admitted_at,
    care_team_ids: [],
    status: :pre_admission
  ]

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because `Healthcare.Patient` is defined again
  # in `lib/healthcare/patient_discharge.ex`. BEAM will replace the first
  # definition with the second at compile time. `admit/2` will be unreachable
  # if the discharge file compiles last, blocking all patient admissions.

  @spec admit(map(), map()) :: {:ok, t()} | {:error, term()}
  def admit(patient_attrs, admission_attrs) do
    admission_type = Map.get(admission_attrs, :type, :elective)
    ward_id = Map.get(admission_attrs, :ward_id)

    with {:ok, bed} <- BedManagement.allocate(ward_id, admission_type),
         {:ok, insurance_status} <- verify_insurance(patient_attrs[:insurance_id]),
         :ok <- validate_insurance(insurance_status, admission_type) do
      patient = %__MODULE__{
        id: generate_id(),
        mrn: generate_mrn(),
        first_name: patient_attrs[:first_name],
        last_name: patient_attrs[:last_name],
        date_of_birth: patient_attrs[:date_of_birth],
        gender: patient_attrs[:gender],
        insurance_id: patient_attrs[:insurance_id],
        primary_diagnosis: admission_attrs[:primary_diagnosis],
        admission_type: admission_type,
        ward_id: bed.ward_id,
        bed_id: bed.id,
        admitted_at: DateTime.utc_now(),
        status: :admitted
      }

      care_team = CareTeamAssigner.assign(patient)
      patient = %{patient | care_team_ids: Enum.map(care_team, & &1.id)}

      Repo.insert(:patients, patient)
      ClinicalRecord.initialise(patient)
      Notifier.notify_care_team(patient, :patient_admitted)

      {:ok, patient}
    end
  end

  # VALIDATION: SMELL END

  @spec transfer(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def transfer(%__MODULE__{status: :admitted} = patient, new_ward_id) do
    with {:ok, bed} <- BedManagement.allocate(new_ward_id, patient.admission_type) do
      BedManagement.release(patient.bed_id)
      updated = %{patient | ward_id: new_ward_id, bed_id: bed.id, status: :transferred}
      Repo.update(:patients, patient.id, Map.from_struct(updated))
      Notifier.notify_care_team(updated, :patient_transferred)
      {:ok, updated}
    end
  end

  def transfer(_, _), do: {:error, :patient_not_admitted}

  defp verify_insurance(nil), do: {:ok, :self_pay}
  defp verify_insurance(id), do: InsuranceVerifier.verify(id)

  defp validate_insurance(:denied, :elective), do: {:error, :insurance_denied}
  defp validate_insurance(_, _), do: :ok

  defp generate_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  defp generate_mrn, do: "MRN-" <> :crypto.strong_rand_bytes(6) |> Base.encode16()
end


# ── file: lib/healthcare/patient_discharge.ex ────────────────────────────────

defmodule Healthcare.Patient do
  @moduledoc """
  Handles patient discharge workflows including clinical sign-off,
  bed release, after-care instruction delivery, and follow-up scheduling.
  """

  alias Healthcare.{BedManagement, ClinicalRecord, Notifier, Repo, AuditLog}

  @spec discharge(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def discharge(patient_id, attrs) do
    discharge_type = Map.get(attrs, :type, :routine)
    discharging_physician_id = Map.fetch!(attrs, :physician_id)

    with {:ok, patient} <- Repo.fetch(:patients, patient_id),
         :ok <- validate_admitted(patient),
         {:ok, clinical_record} <- ClinicalRecord.fetch(patient_id),
         :ok <- ClinicalRecord.validate_complete(clinical_record) do
      now = DateTime.utc_now()

      discharge_summary = %{
        patient_id: patient_id,
        physician_id: discharging_physician_id,
        discharge_type: discharge_type,
        discharged_at: now,
        after_care_instructions: Map.get(attrs, :instructions),
        follow_up_date: Map.get(attrs, :follow_up_date),
        prescriptions: Map.get(attrs, :prescriptions, [])
      }

      BedManagement.release(patient.bed_id)

      updated_patient =
        patient
        |> Map.put(:status, :discharged)
        |> Map.put(:discharged_at, now)

      Repo.update(:patients, patient_id, %{status: :discharged, discharged_at: now})
      ClinicalRecord.attach_discharge_summary(clinical_record, discharge_summary)
      Notifier.send_discharge_instructions(patient, discharge_summary)

      AuditLog.write(:patient_discharged, %{
        patient_id: patient_id,
        physician_id: discharging_physician_id
      })

      {:ok, updated_patient}
    end
  end

  @spec discharge_against_advice(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def discharge_against_advice(patient_id, witness_id) do
    with {:ok, patient} <- Repo.fetch(:patients, patient_id),
         :ok <- validate_admitted(patient) do
      BedManagement.release(patient.bed_id)
      updated = Map.put(patient, :status, :discharged)
      Repo.update(:patients, patient_id, %{status: :discharged, ama: true})
      AuditLog.write(:patient_ama_discharge, %{patient_id: patient_id, witness_id: witness_id})
      {:ok, updated}
    end
  end

  defp validate_admitted(%{status: :admitted}), do: :ok
  defp validate_admitted(_), do: {:error, :patient_not_admitted}
end
```
