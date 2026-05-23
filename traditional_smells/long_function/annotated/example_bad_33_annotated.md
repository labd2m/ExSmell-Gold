# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Scheduling.AppointmentService.book/3`
- **Affected function(s):** `book/3`
- **Short explanation:** `book/3` handles availability checks, conflict detection, buffer-time enforcement, booking persistence, calendar-sync, confirmation email, SMS reminder scheduling, and audit recording all inside one long sequential body with no sub-function delegation.

---

```elixir
defmodule Scheduling.AppointmentService do
  @moduledoc """
  Manages appointment bookings for multi-practitioner
  clinics including conflict detection and reminder setup.
  """

  require Logger

  alias Scheduling.{
    Practitioner, Slot, Appointment,
    CalendarSync, Mailer, SMSScheduler, AuditLog
  }

  @buffer_minutes        15
  @reminder_hours_before 24
  @max_daily_bookings    20

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `book/3` blends slot availability
  # verification, conflict-window computation, daily-cap enforcement,
  # appointment persistence, two-way calendar synchronisation,
  # confirmation-email dispatch, SMS reminder scheduling, and audit
  # recording into a single body exceeding 100 lines with no helper
  # extraction for any of the distinct operational steps.
  def book(patient, practitioner_id, requested_slot, opts \\ []) do
    notes      = Keyword.get(opts, :notes, "")
    booked_by  = Keyword.get(opts, :booked_by, patient.id)
    send_reminders = Keyword.get(opts, :send_reminders, true)

    # 1. Validate practitioner exists and is active
    case Practitioner.get(practitioner_id) do
      nil ->
        {:error, :practitioner_not_found}

      %Practitioner{active: false} ->
        {:error, :practitioner_inactive}

      %Practitioner{} = practitioner ->
        # 2. Verify the slot falls within the practitioner's schedule
        working_hours = Practitioner.working_hours_for(practitioner_id, requested_slot.date)

        slot_start = requested_slot.starts_at
        slot_end   = requested_slot.ends_at

        within_schedule =
          working_hours != nil and
          DateTime.compare(slot_start, working_hours.opens_at) != :lt and
          DateTime.compare(slot_end,   working_hours.closes_at) != :gt

        unless within_schedule do
          {:error, :outside_working_hours}
        else
          # 3. Check buffer window around the requested slot
          buffer_start = DateTime.add(slot_start, -@buffer_minutes * 60, :second)
          buffer_end   = DateTime.add(slot_end,    @buffer_minutes * 60, :second)

          conflicts =
            Appointment.list_for_practitioner_in_range(
              practitioner_id, buffer_start, buffer_end
            )

          if conflicts != [] do
            {:error, {:time_conflict, Enum.map(conflicts, & &1.id)}}
          else
            # 4. Enforce daily booking cap
            day_count =
              Appointment.count_for_practitioner_on_date(
                practitioner_id, requested_slot.date
              )

            if day_count >= @max_daily_bookings do
              {:error, :daily_cap_reached}
            else
              # 5. Persist the appointment
              appt_attrs = %{
                patient_id:      patient.id,
                practitioner_id: practitioner_id,
                starts_at:       slot_start,
                ends_at:         slot_end,
                status:          :confirmed,
                notes:           notes,
                booked_by:       booked_by,
                booked_at:       DateTime.utc_now()
              }

              case Appointment.insert(appt_attrs) do
                {:error, reason} ->
                  Logger.error("Failed to persist appointment: #{inspect(reason)}")
                  {:error, :persistence_failed}

                {:ok, appointment} ->
                  # 6. Sync to practitioner calendar
                  calendar_event = %{
                    title:       "#{patient.full_name} — #{practitioner.specialty}",
                    starts_at:   slot_start,
                    ends_at:     slot_end,
                    attendees:   [practitioner.calendar_email, patient.email],
                    description: notes
                  }

                  case CalendarSync.create_event(practitioner.calendar_id, calendar_event) do
                    {:ok, event_id} ->
                      Appointment.update_calendar_event_id(appointment.id, event_id)

                    {:error, reason} ->
                      Logger.warning("Calendar sync failed: #{inspect(reason)}")
                  end

                  # 7. Send confirmation email to patient
                  email_body = """
                  Dear #{patient.first_name},

                  Your appointment has been confirmed:

                  Practitioner : #{practitioner.full_name} (#{practitioner.specialty})
                  Date & Time  : #{slot_start}
                  Location     : #{practitioner.clinic_address}
                  Notes        : #{notes}

                  Please arrive 10 minutes early.
                  """

                  case Mailer.send_email(patient.email, "Appointment Confirmed", email_body) do
                    {:ok, _}         -> :ok
                    {:error, reason} -> Logger.warning("Confirmation email failed: #{inspect(reason)}")
                  end

                  # 8. Schedule SMS reminder
                  if send_reminders and patient.phone do
                    reminder_at = DateTime.add(slot_start, -@reminder_hours_before * 3600, :second)

                    sms_body = "Reminder: appointment with #{practitioner.full_name} on #{slot_start}. Reply CANCEL to cancel."

                    case SMSScheduler.schedule(%{to: patient.phone, body: sms_body, send_at: reminder_at}) do
                      {:ok, _}         -> :ok
                      {:error, reason} -> Logger.warning("SMS schedule failed: #{inspect(reason)}")
                    end
                  end

                  # 9. Write audit record
                  AuditLog.insert(%AuditLog{
                    action:     "appointment_booked",
                    entity:     "appointment",
                    entity_id:  appointment.id,
                    actor:      to_string(booked_by),
                    metadata:   %{practitioner_id: practitioner_id, patient_id: patient.id},
                    inserted_at: DateTime.utc_now()
                  })

                  Logger.info("Appointment #{appointment.id} booked for patient #{patient.id}")
                  {:ok, appointment}
              end
            end
          end
        end
    end
  end
  # VALIDATION: SMELL END
end
```
