```elixir
defmodule Healthcare.PatientAppointment do
  @moduledoc "Represents a scheduled patient appointment."

  defstruct [
    :id,
    :patient_id,
    :provider_id,
    :appointment_type,
    :scheduled_at,
    :duration_minutes,
    :location,
    :telehealth,
    :preparation_required,
    :preparation_notes,
    :confirmation_status,
    :contact_preference,
    :patient_phone,
    :patient_email,
    :reminder_sent_at
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      patient_id: "PAT-3301",
      provider_id: "PROV-77",
      appointment_type: :follow_up,
      scheduled_at: ~U[2024-04-10 09:30:00Z],
      duration_minutes: 30,
      location: "Clinic B, Room 12",
      telehealth: false,
      preparation_required: true,
      preparation_notes: "Fast for 4 hours before appointment.",
      confirmation_status: :pending,
      contact_preference: :sms,
      patient_phone: "+1-555-0144",
      patient_email: "patient@example.com",
      reminder_sent_at: nil
    }
  end

  def hours_until(%__MODULE__{scheduled_at: scheduled}) do
    DateTime.diff(scheduled, DateTime.utc_now(), :second) / 3600
  end

  def requires_preparation?(%__MODULE__{preparation_required: true}), do: true
  def requires_preparation?(_), do: false

  def preferred_contact(%__MODULE__{contact_preference: pref}), do: pref

  def confirmation_status(%__MODULE__{confirmation_status: status}), do: status

  def is_telehealth?(%__MODULE__{telehealth: true}), do: true
  def is_telehealth?(_), do: false

  def appointment_label(%__MODULE__{appointment_type: type, scheduled_at: at}) do
    "#{type} on #{DateTime.to_date(at)}"
  end
end

defmodule Healthcare.ReminderChannel do
  @moduledoc "Dispatches reminders through the appropriate channel."

  def send(:sms, phone, message) do
    {:ok, %{channel: :sms, destination: phone, message: message}}
  end

  def send(:email, email, message) do
    {:ok, %{channel: :email, destination: email, message: message}}
  end

  def send(channel, _, _), do: {:error, {:unsupported_channel, channel}}
end

defmodule Healthcare.ReminderService do
  @moduledoc """
  Dispatches appointment reminders to patients through their preferred
  contact channel. Reminders are sent 24 hours and 2 hours before the
  appointment.
  """

  alias Healthcare.{PatientAppointment, ReminderChannel}
  require Logger

  @doc """
  Evaluates a list of appointment IDs and sends reminders for those
  falling within the configured reminder windows.
  """
  def process_pending_reminders(appointment_ids) do
    appointment_ids
    |> Enum.filter(fn id ->
      appt  = PatientAppointment.get!(id)
      hours = PatientAppointment.hours_until(appt)
      hours > 0 and hours <= 24 and
        PatientAppointment.confirmation_status(appt) != :confirmed
    end)
    |> Enum.map(fn id ->
      payload = build_reminder_payload(id)
      appt    = PatientAppointment.get!(id)
      channel = PatientAppointment.preferred_contact(appt)

      destination =
        case channel do
          :sms   -> appt.patient_phone
          :email -> appt.patient_email
          _      -> appt.patient_email
        end

      result = ReminderChannel.send(channel, destination, payload.message)
      Logger.info("Reminder sent for appointment #{id}: #{inspect(result)}")
      {id, result}
    end)
  end

  defp build_reminder_payload(appointment_id) do
    appt        = PatientAppointment.get!(appointment_id)
    hours       = PatientAppointment.hours_until(appt)
    needs_prep  = PatientAppointment.requires_preparation?(appt)
    channel     = PatientAppointment.preferred_contact(appt)
    telehealth  = PatientAppointment.is_telehealth?(appt)

    urgency = if hours <= 2, do: "URGENT: ", else: ""

    location_note =
      if telehealth do
        "Join via the telehealth link in your patient portal."
      else
        "Location: #{appt.location}"
      end

    prep_note =
      if needs_prep do
        "\nPreparation required: #{appt.preparation_notes}"
      else
        ""
      end

    message =
      "#{urgency}Reminder: you have a #{appt.appointment_type} appointment " <>
      "on #{DateTime.to_date(appt.scheduled_at)} at #{DateTime.to_time(appt.scheduled_at)}. " <>
      "#{location_note}#{prep_note}"

    %{
      appointment_id: appointment_id,
      channel:        channel,
      hours_until:    Float.round(hours, 1),
      message:        message
    }
  end
end
```
