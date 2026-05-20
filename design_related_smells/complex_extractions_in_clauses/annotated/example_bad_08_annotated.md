# Annotated Example 08 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                              |
|------------------------|----------------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                                     |
| **Expected location**  | `Scheduling.AppointmentBooker.book/1`                                                              |
| **Affected function**  | `book/1`                                                                                           |
| **Short explanation**  | Each clause head extracts `slot_status` (for clause selection) and `scheduled_at` (for the guard), but also eagerly binds `appointment_id`, `patient_id`, `provider_id`, `service_code`, and `notes` — none of which appear in any guard or influence which clause is selected. With three clauses, the five body-only extractions bloat every function head and make the actual dispatch conditions harder to identify quickly. |

---

```elixir
defmodule Scheduling.AppointmentBooker do
  @moduledoc """
  Handles the booking lifecycle for patient appointments.
  Validates slot availability, enforces booking windows, records
  confirmations, and dispatches reminder tasks.
  """

  require Logger

  alias Scheduling.{
    SlotRegistry,
    ProviderCalendar,
    ReminderScheduler,
    PatientRecord,
    AuditLog,
    Notifier
  }

  @booking_window_days 90
  @min_advance_hours 1

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `appointment_id`, `patient_id`,
  # `provider_id`, `service_code`, and `notes` are destructured in the function
  # head of all three clauses despite playing no role in dispatch. Clause
  # selection is driven solely by `slot_status`, and the guard uses
  # `scheduled_at` to enforce the booking window. A developer reading the three
  # clause heads must mentally separate five body-only bindings from the two
  # bindings that actually control which clause executes.
  def book(%Scheduling.AppointmentRequest{
        appointment_id: appointment_id,
        patient_id: patient_id,
        provider_id: provider_id,
        service_code: service_code,
        notes: notes,
        slot_status: :available,
        scheduled_at: scheduled_at
      })
      when scheduled_at > :os.system_time(:second) + @min_advance_hours * 3600 and
             scheduled_at < :os.system_time(:second) + @booking_window_days * 86_400 do
    Logger.info(
      "[AppointmentBooker] Booking appointment #{appointment_id} for patient #{patient_id} " <>
        "with provider #{provider_id} on service #{service_code}"
    )

    with {:ok, patient} <- PatientRecord.fetch(patient_id),
         :ok <- check_patient_eligibility(patient, service_code),
         :ok <- SlotRegistry.reserve(provider_id, scheduled_at, appointment_id),
         {:ok, cal_entry} <- ProviderCalendar.insert(provider_id, appointment_id, scheduled_at, service_code),
         {:ok, _reminder} <- ReminderScheduler.schedule(appointment_id, patient_id, scheduled_at),
         :ok <- Notifier.send_confirmation(patient_id, appointment_id, scheduled_at, provider_id),
         :ok <- AuditLog.write(:appointment_booked, patient_id, %{
                  appointment_id: appointment_id,
                  provider_id: provider_id,
                  service_code: service_code,
                  scheduled_at: scheduled_at,
                  cal_entry_id: cal_entry.id,
                  notes: notes
                }) do
      Logger.info("[AppointmentBooker] Appointment #{appointment_id} confirmed")
      {:ok, :booked, appointment_id}
    else
      {:error, :not_eligible} ->
        Logger.warning("[AppointmentBooker] Patient #{patient_id} not eligible for #{service_code}")
        {:error, :patient_not_eligible}

      {:error, :slot_no_longer_available} ->
        Logger.warning("[AppointmentBooker] Slot taken while booking #{appointment_id}")
        {:error, :slot_taken}

      {:error, reason} ->
        Logger.error("[AppointmentBooker] Booking #{appointment_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def book(%Scheduling.AppointmentRequest{
        appointment_id: appointment_id,
        patient_id: patient_id,
        provider_id: provider_id,
        service_code: service_code,
        notes: _notes,
        slot_status: :available,
        scheduled_at: scheduled_at
      })
      when scheduled_at <= :os.system_time(:second) + @min_advance_hours * 3600 do
    Logger.warning(
      "[AppointmentBooker] Rejected same-hour booking #{appointment_id} for patient #{patient_id}. " <>
        "Minimum advance notice is #{@min_advance_hours}h."
    )

    AuditLog.write(:booking_rejected, patient_id, %{
      appointment_id: appointment_id,
      provider_id: provider_id,
      service_code: service_code,
      reason: :insufficient_advance_notice
    })

    {:error, :insufficient_advance_notice}
  end

  def book(%Scheduling.AppointmentRequest{
        appointment_id: appointment_id,
        patient_id: patient_id,
        provider_id: provider_id,
        service_code: service_code,
        notes: notes,
        slot_status: :waitlist,
        scheduled_at: scheduled_at
      })
      when scheduled_at > :os.system_time(:second) do
    Logger.info(
      "[AppointmentBooker] Adding patient #{patient_id} to waitlist for provider #{provider_id} " <>
        "on #{service_code} at slot #{scheduled_at}"
    )

    with :ok <- Scheduling.Waitlist.enqueue(patient_id, provider_id, service_code, scheduled_at),
         :ok <- Notifier.send_waitlist_confirmation(patient_id, appointment_id, provider_id),
         :ok <- AuditLog.write(:waitlist_joined, patient_id, %{
                  appointment_id: appointment_id,
                  provider_id: provider_id,
                  service_code: service_code,
                  notes: notes
                }) do
      {:ok, :waitlisted, appointment_id}
    else
      {:error, reason} ->
        Logger.error("[AppointmentBooker] Waitlist enqueue failed for #{appointment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def book(%Scheduling.AppointmentRequest{
        appointment_id: appointment_id,
        slot_status: :unavailable
      }) do
    Logger.info("[AppointmentBooker] Slot unavailable for appointment request #{appointment_id}")
    {:error, :slot_unavailable}
  end

  def book(%Scheduling.AppointmentRequest{appointment_id: appointment_id, slot_status: status}) do
    Logger.error("[AppointmentBooker] Unknown slot status '#{status}' on request #{appointment_id}")
    {:error, :unknown_slot_status}
  end

  # --- Private helpers ---

  defp check_patient_eligibility(%{eligible_services: eligible}, service_code) do
    if service_code in eligible do
      :ok
    else
      {:error, :not_eligible}
    end
  end
end
```
