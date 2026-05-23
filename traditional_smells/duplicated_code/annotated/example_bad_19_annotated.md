# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Healthcare.Records.admit_patient/2` and `Healthcare.Records.transfer_patient/3` |
| **Affected functions** | `admit_patient/2`, `transfer_patient/3` |
| **Short explanation** | Both functions duplicate the logic that checks whether a ward has available bed capacity: counting current active admissions in the target ward and comparing against the ward's max bed count. If the bed-availability rule changes (e.g., keeping a buffer for emergency), both functions must be updated identically. |

```elixir
defmodule Healthcare.Records do
  @moduledoc """
  Manages hospital patient admissions, transfers, and discharge records.
  Enforces bed capacity constraints across wards.
  """

  alias Healthcare.Repo
  alias Healthcare.Patient
  alias Healthcare.Admission
  alias Healthcare.Ward
  alias Healthcare.StaffNotification

  @doc """
  Admits a patient to a specified ward.
  Validates that the ward has available beds before admitting.
  """
  def admit_patient(%Patient{} = patient, %Ward{} = ward) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the bed availability check —
    # counting active admissions in the ward and comparing to max_beds —
    # is duplicated in transfer_patient/3. Any change to the capacity check
    # (e.g., ICU buffer beds) must be applied in both functions.
    active_admissions = Repo.count(Admission, ward_id: ward.id, status: :active)

    if active_admissions >= ward.max_beds do
      {:error, {:ward_full, ward.id}}
    else
      :capacity_ok
    end
    # VALIDATION: SMELL END
    |> case do
      :capacity_ok ->
        admission = %Admission{
          patient_id: patient.id,
          ward_id: ward.id,
          admitted_at: DateTime.utc_now(),
          status: :active,
          admission_type: :planned
        }

        with {:ok, saved} <- Repo.insert(admission) do
          StaffNotification.alert_ward(ward, :new_admission, patient)
          {:ok, saved}
        end

      error ->
        error
    end
  end

  @doc """
  Transfers an active patient from their current ward to a target ward.
  Validates capacity at the destination ward before transferring.
  """
  def transfer_patient(%Patient{} = patient, current_admission, %Ward{} = target_ward) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because this bed availability check is a
    # copy of the same logic in admit_patient/2.
    active_admissions = Repo.count(Admission, ward_id: target_ward.id, status: :active)

    if active_admissions >= target_ward.max_beds do
      {:error, {:ward_full, target_ward.id}}
    else
      :capacity_ok
    end
    # VALIDATION: SMELL END
    |> case do
      :capacity_ok ->
        Repo.update!(%{current_admission | status: :transferred, discharged_at: DateTime.utc_now()})

        new_admission = %Admission{
          patient_id: patient.id,
          ward_id: target_ward.id,
          admitted_at: DateTime.utc_now(),
          status: :active,
          admission_type: :transfer
        }

        with {:ok, saved} <- Repo.insert(new_admission) do
          StaffNotification.alert_ward(target_ward, :transfer_in, patient)
          {:ok, saved}
        end

      error ->
        error
    end
  end

  @doc """
  Discharges a patient from the hospital.
  """
  def discharge(%Patient{} = patient, discharge_notes) do
    case Repo.get_by(Admission, patient_id: patient.id, status: :active) do
      nil ->
        {:error, :no_active_admission}

      admission ->
        updated = %{
          admission
          | status: :discharged,
            discharged_at: DateTime.utc_now(),
            discharge_notes: discharge_notes
        }

        Repo.update(updated)
    end
  end

  @doc """
  Returns a bed occupancy summary for all wards.
  """
  def ward_occupancy_summary do
    Repo.all(Ward)
    |> Enum.map(fn ward ->
      occupied = Repo.count(Admission, ward_id: ward.id, status: :active)
      %{ward_id: ward.id, name: ward.name, occupied: occupied, total: ward.max_beds, available: ward.max_beds - occupied}
    end)
  end
end
```
