# Annotated Example 08 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Scheduling.Appointments.book_appointment/12`
- **Affected function(s):** `book_appointment/12`
- **Short explanation:** The function takes 12 separate positional parameters spanning patient info, practitioner info, time slot details, and preferences. These should be structured into dedicated `Patient`, `Slot`, and options types.

---

```elixir
defmodule Scheduling.Appointments do
  @moduledoc """
  Handles booking, rescheduling, and cancellation of appointments in the scheduling system.
  """

  require Logger

  alias Scheduling.{
    Appointment,
    AvailabilityChecker,
    CalendarSync,
    ReminderService,
    Repo
  }

  @appointment_types [:consultation, :follow_up, :procedure, :telemedicine]
  @reminder_methods [:email, :sms, :both, :none]

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 12 parameters are specified positionally.
  # VALIDATION: Patient contact info, practitioner identification, time slot details,
  # VALIDATION: and reminder preferences are entirely separate concerns that should
  # VALIDATION: be grouped into structs or option maps.
  def book_appointment(
        patient_id,
        patient_name,
        patient_email,
        patient_phone,
        practitioner_id,
        location_id,
        appointment_type,
        start_time,
        end_time,
        notes,
        reminder_method,
        sync_to_calendar
      ) do
    # VALIDATION: SMELL END

    with :ok <- validate_appointment_type(appointment_type),
         :ok <- validate_time_slot(start_time, end_time),
         :ok <- validate_reminder_method(reminder_method),
         :ok <- AvailabilityChecker.check(practitioner_id, location_id, start_time, end_time) do

      appointment = %Appointment{
        id: generate_appointment_id(),
        patient: %{
          id: patient_id,
          name: patient_name,
          email: patient_email,
          phone: patient_phone
        },
        practitioner_id: practitioner_id,
        location_id: location_id,
        type: appointment_type,
        start_time: start_time,
        end_time: end_time,
        duration_minutes: DateTime.diff(end_time, start_time, :second) |> div(60),
        notes: notes,
        status: :confirmed,
        booked_at: DateTime.utc_now()
      }

      case Repo.insert(appointment) do
        {:ok, saved} ->
          schedule_reminders(saved, reminder_method, patient_email, patient_phone)

          if sync_to_calendar do
            CalendarSync.sync(saved)
          end

          Logger.info("Appointment #{saved.id} booked for patient #{patient_id}")
          {:ok, saved}

        {:error, reason} ->
          Logger.error("Failed to book appointment: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def cancel_appointment(appointment_id, reason \\ nil) do
    case Repo.get(Appointment, appointment_id) do
      nil ->
        {:error, :not_found}

      appointment ->
        updated = struct(appointment, status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now())
        Repo.update(updated)
        ReminderService.cancel_pending(appointment_id)
        Logger.info("Appointment #{appointment_id} cancelled")
        :ok
    end
  end

  defp schedule_reminders(appointment, :none, _email, _phone), do: :ok

  defp schedule_reminders(appointment, :email, email, _phone) do
    ReminderService.schedule(appointment.id, :email, email, appointment.start_time)
  end

  defp schedule_reminders(appointment, :sms, _email, phone) do
    ReminderService.schedule(appointment.id, :sms, phone, appointment.start_time)
  end

  defp schedule_reminders(appointment, :both, email, phone) do
    ReminderService.schedule(appointment.id, :email, email, appointment.start_time)
    ReminderService.schedule(appointment.id, :sms, phone, appointment.start_time)
  end

  defp validate_appointment_type(t) when t in @appointment_types, do: :ok
  defp validate_appointment_type(t), do: {:error, {:invalid_type, t}}

  defp validate_reminder_method(m) when m in @reminder_methods, do: :ok
  defp validate_reminder_method(m), do: {:error, {:invalid_reminder_method, m}}

  defp validate_time_slot(start_time, end_time) do
    if DateTime.compare(end_time, start_time) == :gt,
      do: :ok,
      else: {:error, :invalid_time_slot}
  end

  defp generate_appointment_id do
    "APT-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
