```elixir
defmodule Scheduling.Appointments do
  @moduledoc """
  Handles appointment booking for the healthcare scheduling service.
  """

  require Logger

  @slot_duration_minutes 30
  @reminder_lead_hours 24

  def book(
        patient_id,
        patient_name,
        patient_phone,
        provider_id,
        provider_name,
        appointment_date,
        appointment_time,
        duration_minutes,
        appointment_type,
        send_sms_reminder,
        send_email_reminder
      ) do
    with :ok <- validate_ids(patient_id, provider_id),
         :ok <- validate_datetime(appointment_date, appointment_time),
         :ok <- validate_duration(duration_minutes),
         :ok <- validate_type(appointment_type),
         :ok <- check_availability(provider_id, appointment_date, appointment_time, duration_minutes) do
      appointment = %{
        id: generate_appointment_id(),
        patient: %{id: patient_id, name: patient_name, phone: patient_phone},
        provider: %{id: provider_id, name: provider_name},
        scheduled_at: NaiveDateTime.new!(appointment_date, appointment_time),
        duration_minutes: duration_minutes,
        type: appointment_type,
        reminders: %{sms: send_sms_reminder, email: send_email_reminder},
        status: :confirmed,
        booked_at: DateTime.utc_now()
      }

      case persist_appointment(appointment) do
        {:ok, saved} ->
          Logger.info("Appointment #{saved.id} booked: #{provider_name} / #{patient_name} on #{appointment_date}")
          schedule_reminders(saved)
          {:ok, saved}

        {:error, :conflict} ->
          {:error, :slot_no_longer_available}

        {:error, reason} ->
          Logger.error("Booking failed: #{inspect(reason)}")
          {:error, :booking_failed}
      end
    end
  end

  defp validate_ids(patient_id, provider_id) when is_binary(patient_id) and is_binary(provider_id), do: :ok
  defp validate_ids(_, _), do: {:error, "patient_id and provider_id must be strings"}

  defp validate_datetime(%Date{} = date, %Time{} = time) do
    scheduled = NaiveDateTime.new!(date, time)
    if NaiveDateTime.compare(scheduled, NaiveDateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, "appointment must be in the future"}
  end
  defp validate_datetime(_, _), do: {:error, "invalid date or time type"}

  defp validate_duration(d) when d > 0 and rem(d, @slot_duration_minutes) == 0, do: :ok
  defp validate_duration(d), do: {:error, "duration #{d} is not a multiple of #{@slot_duration_minutes}"}

  defp validate_type(type) when type in [:consultation, :follow_up, :procedure, :telemedicine], do: :ok
  defp validate_type(type), do: {:error, "unknown appointment type: #{inspect(type)}"}

  defp check_availability(provider_id, date, time, duration) do
    Logger.debug("Checking availability for provider #{provider_id} at #{date} #{time} for #{duration}m")
    :ok
  end

  defp persist_appointment(appointment) do
    {:ok, appointment}
  end

  defp schedule_reminders(%{reminders: %{sms: false, email: false}}), do: :ok
  defp schedule_reminders(appointment) do
    lead = appointment.scheduled_at
    |> NaiveDateTime.add(-@reminder_lead_hours * 3600, :second)

    if appointment.reminders.sms do
      Logger.debug("SMS reminder queued for #{appointment.patient.phone} at #{lead}")
    end

    if appointment.reminders.email do
      Logger.debug("Email reminder queued for appointment #{appointment.id} at #{lead}")
    end

    :ok
  end

  defp generate_appointment_id do
    "APT-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
