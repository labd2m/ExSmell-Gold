# Annotated Example 18 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Scheduling.Appointments.book_appointment/10` |
| **Affected function(s)** | `book_appointment/10` |
| **Explanation** | The function takes 10 positional parameters spanning patient info (patient_id, patient_name, patient_email), provider details (provider_id, specialty), timing (date, start_time, duration_minutes), and options (notes, send_reminder). These naturally belong in a `%Patient{}`, `%Provider{}`, and `%AppointmentOptions{}` structure instead of a flat argument list. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `book_appointment/10` accepts ten
# individual positional parameters. Patient contact data (patient_id,
# patient_name, patient_email), provider data (provider_id, specialty),
# scheduling details (date, start_time, duration_minutes), and booking
# options (notes, send_reminder) are all mixed into one long signature.
# Grouping into focused structs would make each call site readable
# and reduce the risk of transposing arguments of the same type.
defmodule Scheduling.Appointments do
  @moduledoc """
  Handles appointment booking, conflict detection, and reminder scheduling
  for the clinical scheduling subsystem.
  """

  require Logger

  alias Scheduling.Repo
  alias Scheduling.Schemas.Appointment
  alias Scheduling.AvailabilityChecker
  alias Scheduling.ReminderWorker
  alias Scheduling.Mailer

  @max_duration_minutes 240
  @reminder_hours_before 24

  def book_appointment(
        patient_id,
        patient_name,
        patient_email,
        provider_id,
        specialty,
        date,
        start_time,
        duration_minutes,
        notes,
        send_reminder
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_date(date),
         :ok <- validate_time(start_time),
         :ok <- validate_duration(duration_minutes),
         :ok <- validate_email(patient_email) do
      {:ok, slot_start} = NaiveDateTime.new(date, start_time)
      slot_end = NaiveDateTime.add(slot_start, duration_minutes * 60, :second)

      case AvailabilityChecker.check(provider_id, slot_start, slot_end) do
        :available ->
          attrs = %{
            patient_id: patient_id,
            patient_name: patient_name,
            patient_email: patient_email,
            provider_id: provider_id,
            specialty: specialty,
            starts_at: slot_start,
            ends_at: slot_end,
            duration_minutes: duration_minutes,
            notes: notes,
            status: :confirmed,
            inserted_at: DateTime.utc_now()
          }

          case Repo.insert(Appointment.changeset(%Appointment{}, attrs)) do
            {:ok, appt} ->
              if send_reminder do
                remind_at =
                  NaiveDateTime.add(slot_start, -@reminder_hours_before * 3600, :second)

                ReminderWorker.schedule(%{
                  appointment_id: appt.id,
                  patient_email: patient_email,
                  remind_at: remind_at
                })
              end

              Mailer.send_confirmation(patient_email, patient_name, appt)
              Logger.info("Appointment #{appt.id} booked for patient #{patient_id}")
              {:ok, appt}

            {:error, changeset} ->
              Logger.error("Booking failed: #{inspect(changeset.errors)}")
              {:error, :booking_failed}
          end

        :unavailable ->
          {:error, :slot_not_available}

        {:error, reason} ->
          Logger.error("Availability check error: #{reason}")
          {:error, :availability_check_failed}
      end
    end
  end

  defp validate_date(date) do
    case Date.from_iso8601(date) do
      {:ok, d} ->
        if Date.compare(d, Date.utc_today()) != :lt, do: :ok, else: {:error, :date_in_past}

      _ ->
        {:error, :invalid_date}
    end
  end

  defp validate_time(time) do
    case Time.from_iso8601(time) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_time}
    end
  end

  defp validate_duration(d) when is_integer(d) and d > 0 and d <= @max_duration_minutes, do: :ok
  defp validate_duration(_), do: {:error, :invalid_duration}

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") do
      :ok
    else
      {:error, :invalid_email}
    end
  end
end
```
