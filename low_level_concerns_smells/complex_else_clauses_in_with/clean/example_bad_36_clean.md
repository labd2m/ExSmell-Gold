```elixir
defmodule Scheduling.AppointmentBooker do
  @moduledoc """
  Orchestrates appointment booking: provider resolution, availability
  check, conflict detection, slot reservation, and confirmation dispatch.
  """

  alias Scheduling.{
    ProviderRepo,
    AvailabilityEngine,
    ConflictChecker,
    SlotRegistry,
    ConfirmationMailer
  }

  require Logger

  @doc """
  Books an appointment for `patient_id` with `provider_id` at `slot`.

  `slot` is a `%{date: Date.t(), time: Time.t(), duration_minutes: pos_integer()}`.

  Returns `{:ok, appointment}` or a descriptive error.
  """
  @spec book_appointment(String.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :provider_not_found}
          | {:error, :slot_unavailable}
          | {:error, :patient_conflict}
          | {:error, :reservation_failed}
          | {:error, :confirmation_failed}
  def book_appointment(patient_id, provider_id, slot) do
    with {:ok, provider}     <- ProviderRepo.fetch(provider_id),
         {:ok, availability} <- AvailabilityEngine.check(provider, slot),
         :ok                 <- ConflictChecker.check_patient(patient_id, slot),
         {:ok, reservation}  <- SlotRegistry.reserve(availability.slot_id, patient_id),
         {:ok, confirmation} <- ConfirmationMailer.send(patient_id, provider, reservation) do
      appointment = %{
        id:              reservation.id,
        patient_id:      patient_id,
        provider_id:     provider_id,
        date:            slot.date,
        time:            slot.time,
        duration:        slot.duration_minutes,
        confirmation_no: confirmation.number,
        status:          :confirmed,
        booked_at:       DateTime.utc_now()
      }

      Logger.info("Appointment #{appointment.id} booked for patient #{patient_id}")
      {:ok, appointment}
    else
      {:error, :not_found} ->
        Logger.warn("Provider #{provider_id} not found")
        {:error, :provider_not_found}

      {:error, :unavailable, reason} ->
        Logger.info("Slot unavailable for provider #{provider_id}: #{reason}")
        {:error, :slot_unavailable}

      {:conflict, conflicting_slot} ->
        Logger.info("Patient #{patient_id} has conflict with #{inspect(conflicting_slot)}")
        {:error, :patient_conflict}

      {:error, :reserve, detail} ->
        Logger.error("Slot reservation failed: #{inspect(detail)}")
        {:error, :reservation_failed}

      {:error, :mail} ->
        Logger.error("Confirmation email failed for appointment")
        {:error, :confirmation_failed}
    end
  end
end
```
