```elixir
defmodule Scheduling.AppointmentBooker do
  alias Scheduling.{Repo, Provider, Patient, Slot, Appointment, NotificationService}

  require Logger

  def book_appointment(slot_id, patient_id, notes) do
    with {:ok, slot} <- fetch_open_slot(slot_id),
         {:ok, provider} <- fetch_available_provider(slot.provider_id),
         {:ok, patient} <- fetch_eligible_patient(patient_id),
         :ok <- check_booking_rules(provider, patient, slot),
         {:ok, appointment} <- persist_appointment(slot, patient, provider, notes) do
      slot |> Slot.changeset(%{status: :booked}) |> Repo.update()

      NotificationService.send_confirmation(patient, provider, appointment)

      Logger.info(
        "Appointment #{appointment.id} booked: " <>
          "patient=#{patient_id} provider=#{provider.id} slot=#{slot_id}"
      )

      {:ok, appointment}
    else
      {:error, :slot_not_found} ->
        Logger.warning("Slot #{slot_id} not found")
        {:error, :slot_unavailable}

      {:error, :slot_not_open} ->
        Logger.warning("Slot #{slot_id} is no longer open")
        {:error, :slot_unavailable}

      {:error, :provider_not_found} ->
        Logger.error("Provider for slot #{slot_id} not found")
        {:error, :provider_error}

      {:error, :provider_unavailable} ->
        Logger.warning("Provider is unavailable for slot #{slot_id}")
        {:error, :provider_error}

      {:error, :patient_not_found} ->
        Logger.warning("Patient #{patient_id} not found")
        {:error, :patient_not_found}

      {:error, :patient_ineligible} ->
        Logger.warning("Patient #{patient_id} is not eligible for booking")
        {:error, :patient_ineligible}

      {:error, :max_appointments_reached} ->
        Logger.warning("Patient #{patient_id} has reached the max appointment limit")
        {:error, :booking_not_allowed}

      {:error, :specialization_mismatch} ->
        Logger.warning("Provider specialization does not match patient need")
        {:error, :booking_not_allowed}

      {:error, :duplicate_booking} ->
        Logger.warning("Duplicate booking detected for patient #{patient_id} / slot #{slot_id}")
        {:error, :duplicate_booking}
    end
  end

  defp fetch_open_slot(slot_id) do
    case Repo.get(Slot, slot_id) do
      nil -> {:error, :slot_not_found}
      %Slot{status: :open} = slot -> {:ok, slot}
      _ -> {:error, :slot_not_open}
    end
  end

  defp fetch_available_provider(provider_id) do
    case Repo.get(Provider, provider_id) do
      nil -> {:error, :provider_not_found}
      %Provider{available: false} -> {:error, :provider_unavailable}
      provider -> {:ok, provider}
    end
  end

  defp fetch_eligible_patient(patient_id) do
    case Repo.get(Patient, patient_id) do
      nil -> {:error, :patient_not_found}
      %Patient{active: false} -> {:error, :patient_ineligible}
      patient -> {:ok, patient}
    end
  end

  defp check_booking_rules(provider, patient, slot) do
    existing_count = Repo.count(from a in Appointment,
      where: a.patient_id == ^patient.id and a.status in [:pending, :confirmed]
    )

    cond do
      existing_count >= 3 ->
        {:error, :max_appointments_reached}

      !compatible_specialization?(provider, patient) ->
        {:error, :specialization_mismatch}

      already_booked_same_day?(patient, slot) ->
        {:error, :duplicate_booking}

      true ->
        :ok
    end
  end

  defp persist_appointment(slot, patient, provider, notes) do
    Repo.insert(%Appointment{
      slot_id: slot.id,
      patient_id: patient.id,
      provider_id: provider.id,
      notes: notes,
      status: :confirmed,
      scheduled_at: slot.starts_at
    })
  end

  defp compatible_specialization?(provider, patient) do
    patient.required_specialization in provider.specializations
  end

  defp already_booked_same_day?(patient, slot) do
    date = DateTime.to_date(slot.starts_at)

    Repo.exists?(
      from a in Appointment,
        where:
          a.patient_id == ^patient.id and
            fragment("DATE(?)", a.scheduled_at) == ^date and
            a.status != :cancelled
    )
  end
end
```
