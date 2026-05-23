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
    active_admissions = Repo.count(Admission, ward_id: ward.id, status: :active)

    if active_admissions >= ward.max_beds do
      {:error, {:ward_full, ward.id}}
    else
      :capacity_ok
    end
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
    active_admissions = Repo.count(Admission, ward_id: target_ward.id, status: :active)

    if active_admissions >= target_ward.max_beds do
      {:error, {:ward_full, target_ward.id}}
    else
      :capacity_ok
    end
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
