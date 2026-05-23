```elixir
defmodule Scheduling.ReminderDispatcher do
  @moduledoc """
  Dispatches appointment reminders across configured channels
  (SMS, email, push notification). Jobs are enqueued by the
  appointment scheduler 24 h and 1 h before each appointment start.
  """

  alias Scheduling.{Appointment, Patient, Provider, Location}
  alias Notifications.{SmsGateway, EmailMailer, PushService}

  @sms_char_limit     160
  @reminder_source    "scheduling"

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Builds and dispatches reminder messages for the given appointment ID.
  Returns a map of `%{channel => :ok | {:error, reason}}`.
  """
  @spec dispatch(String.t()) :: map()
  def dispatch(appointment_id) do
    appointment = Appointment.get!(appointment_id)
    payload     = build_reminder_payload(appointment)
    channels    = payload.channels

    Enum.into(channels, %{}, fn channel ->
      result = deliver(channel, payload)
      {channel, result}
    end)
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp build_reminder_payload(appointment) do
    patient    = Appointment.get_patient(appointment)
    provider   = Appointment.get_provider(appointment)
    location   = Appointment.get_location(appointment)
    cancel_tok = Appointment.cancellation_token(appointment)
    resched_url = Appointment.reschedule_url(appointment)
    channels   = Appointment.reminder_channels(appointment)

    starts_local  = localize_time(appointment.starts_at, location.timezone)
    date_label    = Calendar.strftime(starts_local, "%A, %B %d")
    time_label    = Calendar.strftime(starts_local, "%I:%M %p")
    ends_at       = DateTime.add(appointment.starts_at, appointment.duration_minutes * 60)

    %{
      appointment_id:    appointment.id,
      patient_name:      Patient.first_name(patient),
      patient_phone:     patient.mobile_phone,
      patient_email:     patient.email,
      patient_push_token: patient.push_notification_token,
      provider_name:     Provider.display_name(provider),
      provider_title:    provider.professional_title,
      location_name:     location.name,
      location_address:  Location.formatted_address(location),
      appointment_type:  appointment.appointment_type,
      date_label:        date_label,
      time_label:        time_label,
      duration_minutes:  appointment.duration_minutes,
      ends_at:           ends_at,
      special_notes:     appointment.notes,
      cancel_url:        build_cancel_url(cancel_tok),
      reschedule_url:    resched_url,
      channels:          channels
    }
  end

  defp deliver(:sms, payload) do
    body = sms_body(payload)
    SmsGateway.send(to: payload.patient_phone, body: body, source: @reminder_source)
  end

  defp deliver(:email, payload) do
    EmailMailer.deliver(:appointment_reminder, payload)
  end

  defp deliver(:push, payload) do
    PushService.notify(
      token:   payload.patient_push_token,
      title:   "Upcoming appointment",
      body:    "#{payload.date_label} at #{payload.time_label} with #{payload.provider_name}",
      data:    %{appointment_id: payload.appointment_id}
    )
  end

  defp deliver(unknown, _payload) do
    {:error, {:unknown_channel, unknown}}
  end

  defp sms_body(payload) do
    full = "Reminder: #{payload.appointment_type} on #{payload.date_label} " <>
           "at #{payload.time_label} with #{payload.provider_name}. " <>
           "Cancel: #{payload.cancel_url}"
    if String.length(full) > @sms_char_limit do
      String.slice(full, 0, @sms_char_limit - 3) <> "..."
    else
      full
    end
  end

  defp localize_time(%DateTime{} = dt, timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, local} -> local
      _            -> dt
    end
  end

  defp build_cancel_url(token) do
    base = Application.fetch_env!(:scheduling, :portal_base_url)
    "#{base}/appointments/cancel?token=#{token}"
  end
end
```
