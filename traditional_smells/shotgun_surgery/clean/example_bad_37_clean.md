```elixir
defmodule Scheduling.AppointmentPolicy do
  @moduledoc """
  Defines scheduling constraints for each appointment delivery mode,
  including default durations, room requirements, and buffer times.
  """


  @spec default_duration_minutes(atom()) :: pos_integer()
  def default_duration_minutes(:in_person), do: 60
  def default_duration_minutes(:phone),     do: 30
  def default_duration_minutes(:video),     do: 45

  @spec requires_room_booking?(atom()) :: boolean()
  def requires_room_booking?(:in_person), do: true
  def requires_room_booking?(:phone),     do: false
  def requires_room_booking?(:video),     do: false

  @spec buffer_minutes(atom()) :: non_neg_integer()
  def buffer_minutes(:in_person), do: 15
  def buffer_minutes(:phone),     do: 5
  def buffer_minutes(:video),     do: 5


  def available_slots(provider, date, delivery_type) do
    duration = default_duration_minutes(delivery_type)
    buffer   = buffer_minutes(delivery_type)
    slot_size = duration + buffer

    provider.working_hours
    |> Enum.filter(fn h -> h.date == date end)
    |> Enum.flat_map(fn h -> generate_slots(h.start_time, h.end_time, slot_size) end)
    |> Enum.reject(fn slot -> overlaps_existing?(slot, provider.bookings) end)
  end

  defp generate_slots(start_time, end_time, slot_size) do
    Stream.iterate(start_time, &Time.add(&1, slot_size * 60))
    |> Enum.take_while(&(Time.compare(&1, end_time) == :lt))
    |> Enum.map(fn t -> %{starts_at: t} end)
  end

  defp overlaps_existing?(_slot, _bookings), do: false
end

defmodule Scheduling.ReminderService do
  @moduledoc """
  Schedules and delivers appointment reminders using delivery-mode-appropriate
  lead times and communication channels.
  """


  @spec reminder_lead_time_hours(atom()) :: pos_integer()
  def reminder_lead_time_hours(:in_person), do: 24
  def reminder_lead_time_hours(:phone),     do: 2
  def reminder_lead_time_hours(:video),     do: 4

  @spec reminder_channel(atom()) :: atom()
  def reminder_channel(:in_person), do: :email
  def reminder_channel(:phone),     do: :sms
  def reminder_channel(:video),     do: :email


  def schedule_reminder(appointment) do
    lead_hours = reminder_lead_time_hours(appointment.delivery_type)
    channel    = reminder_channel(appointment.delivery_type)
    send_at    = DateTime.add(appointment.starts_at, -lead_hours * 3600, :second)

    %{
      appointment_id: appointment.id,
      patient_id:     appointment.patient_id,
      channel:        channel,
      send_at:        send_at,
      template:       reminder_template(appointment.delivery_type),
      status:         :pending
    }
  end

  defp reminder_template(:in_person) do
    "reminders/in_person_appointment.html"
  end

  defp reminder_template(:phone) do
    "reminders/phone_appointment.txt"
  end

  defp reminder_template(:video) do
    "reminders/video_appointment.html"
  end
end

defmodule Scheduling.BillingCodes do
  @moduledoc """
  Maps appointment delivery types to CPT/billing codes and determines
  billable status for insurance and invoicing purposes.
  """


  @spec billing_code(atom()) :: String.t()
  def billing_code(:in_person), do: "99213"
  def billing_code(:phone),     do: "99441"
  def billing_code(:video),     do: "99444"

  @spec billable?(atom()) :: boolean()
  def billable?(:in_person), do: true
  def billable?(:phone),     do: true
  def billable?(:video),     do: true


  def build_claim_line(appointment) do
    delivery = appointment.delivery_type

    if billable?(delivery) do
      {:ok, %{
        cpt_code:       billing_code(delivery),
        units:          1,
        provider_npi:   appointment.provider.npi,
        service_date:   DateTime.to_date(appointment.starts_at),
        place_of_service: place_of_service_code(delivery),
        diagnosis_codes: appointment.diagnosis_codes
      }}
    else
      {:skip, :not_billable}
    end
  end

  defp place_of_service_code(:in_person), do: "11"
  defp place_of_service_code(:phone),     do: "02"
  defp place_of_service_code(:video),     do: "02"
end
```
