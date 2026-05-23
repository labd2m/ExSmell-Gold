```elixir
defmodule Scheduling.AppointmentManager do
  @moduledoc """
  Manages healthcare appointment scheduling including slot validation,
  room assignment, preparation time calculation, and patient reminders
  for different appointment types at the clinic.
  """

  alias Scheduling.{Appointment, SlotRegistry, RoomInventory, ReminderQueue, CalendarSync}

  def book_appointment(patient, provider, type, requested_at) do
    with :ok             <- validate_appointment_slot(provider, requested_at, type),
         {:ok, room}     <- reserve_room(type, requested_at),
         {:ok, appt}     <- create_appointment(patient, provider, type, requested_at, room),
         :ok             <- schedule_reminder(appt),
         :ok             <- CalendarSync.push(appt) do
      {:ok, appt}
    end
  end

  defp validate_appointment_slot(provider, requested_at, type) do
    duration = get_duration_minutes(type)
    prep     = get_preparation_minutes(type)
    SlotRegistry.check_availability(provider.id, requested_at, duration + prep)
  end

  defp reserve_room(type, requested_at) do
    room_type = assign_room_type(type)
    RoomInventory.reserve(room_type, requested_at)
  end

  defp create_appointment(patient, provider, type, requested_at, room) do
    duration = get_duration_minutes(type)

    appt = %Appointment{
      patient_id:    patient.id,
      provider_id:   provider.id,
      type:          type,
      starts_at:     requested_at,
      ends_at:       DateTime.add(requested_at, duration * 60, :second),
      room_id:       room.id,
      status:        :confirmed
    }

    SlotRegistry.insert(appt)
  end

  defp schedule_reminder(%Appointment{} = appt) do
    offset_hours = get_reminder_offset_hours(appt.type)
    remind_at    = DateTime.add(appt.starts_at, -offset_hours * 3600, :second)
    ReminderQueue.enqueue(appt.patient_id, appt.id, remind_at)
  end

  def get_duration_minutes(:consultation), do: 30
  def get_duration_minutes(:procedure),   do: 90
  def get_duration_minutes(:follow_up),   do: 15
  def get_duration_minutes(_),            do: 30

  def assign_room_type(:consultation), do: :exam_room
  def assign_room_type(:procedure),    do: :procedure_room
  def assign_room_type(:follow_up),    do: :exam_room
  def assign_room_type(_),             do: :general_room

  def get_preparation_minutes(:consultation), do: 10
  def get_preparation_minutes(:procedure),    do: 30
  def get_preparation_minutes(:follow_up),    do: 5
  def get_preparation_minutes(_),             do: 10

  def get_reminder_offset_hours(:consultation), do: 24
  def get_reminder_offset_hours(:procedure),    do: 48
  def get_reminder_offset_hours(:follow_up),    do: 2
  def get_reminder_offset_hours(_),             do: 24

  def cancel_appointment(%Appointment{status: :confirmed} = appt, reason) do
    with :ok <- SlotRegistry.release(appt),
         :ok <- RoomInventory.release(appt.room_id),
         :ok <- ReminderQueue.cancel(appt.id) do
      CalendarSync.remove(appt)
      SlotRegistry.update_status(appt.id, :cancelled, reason)
    end
  end

  def cancel_appointment(%Appointment{status: status}, _reason) do
    {:error, {:cannot_cancel, status}}
  end

  def reschedule_appointment(%Appointment{} = appt, new_time) do
    with :ok <- cancel_appointment(appt, :rescheduled) do
      book_appointment(
        %{id: appt.patient_id},
        %{id: appt.provider_id},
        appt.type,
        new_time
      )
    end
  end

  def get_upcoming_appointments(provider_id, from \\ DateTime.utc_now()) do
    SlotRegistry.list_by_provider(provider_id, from: from, status: :confirmed)
  end
end
```
