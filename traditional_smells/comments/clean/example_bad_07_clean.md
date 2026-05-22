```elixir
defmodule AppointmentScheduler do
  @moduledoc """
  Manages appointment booking, rescheduling, and cancellation for the
  clinic scheduling platform.
  """

  alias AppointmentScheduler.{
    Slot,
    Appointment,
    Provider,
    CalendarLock,
    ReminderQueue
  }

  @booking_window_days 90
  @min_notice_hours 1

  @doc """
  Returns all available open slots for a given provider within the booking window.
  """
  def available_slots(provider_id, from \\ Date.utc_today()) do
    cutoff = Date.add(from, @booking_window_days)
    Slot.open_between(provider_id, from, cutoff)
  end

  # book_slot/3
  #
  # Books a specific slot for a patient with the designated provider.
  #
  # Conflict detection:
  #   The function acquires a CalendarLock for the provider for the slot's
  #   time window before checking availability. This prevents double-booking
  #   under concurrent request load.
  #
  # Overbooking policy:
  #   A slot may allow multiple bookings if Slot.max_capacity > 1 (e.g.
  #   group therapy sessions). The booking is rejected once occupancy
  #   reaches max_capacity.
  #
  # Minimum notice:
  #   Bookings with a start time fewer than @min_notice_hours hours from
  #   now are rejected with {:error, :insufficient_notice}.
  #
  # Side effects:
  #   On success, a reminder job is enqueued via ReminderQueue for both
  #   24h and 1h before the appointment start.
  #
  # Parameters:
  #   slot_id     - integer slot primary key
  #   patient_id  - integer patient primary key
  #   notes       - optional string of booking notes (may be nil)
  #
  # Returns {:ok, %Appointment{}} or {:error, reason}.
  # inline comments instead of @doc, hiding the conflict-detection policy, capacity
  # rules, notice requirement, and side effects from ExDoc and IEx.h/1.
  def book_slot(slot_id, patient_id, notes \\ nil) do
    with {:ok, slot} <- Slot.fetch(slot_id),
         :ok <- check_notice_window(slot.starts_at),
         {:ok, _lock} <- CalendarLock.acquire(slot.provider_id, slot.starts_at, slot.ends_at),
         :ok <- check_capacity(slot),
         {:ok, appointment} <- Appointment.create(slot_id, patient_id, notes) do
      ReminderQueue.schedule(appointment, offsets_hours: [24, 1])
      {:ok, appointment}
    end
  end

  @doc """
  Cancels an existing appointment and releases the slot back to available inventory.
  """
  def cancel_appointment(appointment_id, reason \\ nil) do
    with {:ok, appointment} <- Appointment.fetch(appointment_id),
         :ok <- ensure_cancellable(appointment),
         {:ok, _} <- Appointment.update(appointment, %{status: :cancelled, cancel_reason: reason}),
         :ok <- Slot.release(appointment.slot_id) do
      ReminderQueue.cancel_for_appointment(appointment_id)
      :ok
    end
  end

  @doc """
  Reschedules an appointment to a new slot, cancelling the old one atomically.
  """
  def reschedule(appointment_id, new_slot_id, patient_id) do
    Repo.transaction(fn ->
      with :ok <- cancel_appointment(appointment_id),
           {:ok, new_appointment} <- book_slot(new_slot_id, patient_id) do
        new_appointment
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp check_notice_window(starts_at) do
    threshold = DateTime.add(DateTime.utc_now(), @min_notice_hours * 3600, :second)

    if DateTime.compare(starts_at, threshold) == :gt do
      :ok
    else
      {:error, :insufficient_notice}
    end
  end

  defp check_capacity(%Slot{max_capacity: max, current_bookings: current})
       when current < max,
       do: :ok

  defp check_capacity(_), do: {:error, :slot_full}

  defp ensure_cancellable(%Appointment{status: status})
       when status in [:pending, :confirmed],
       do: :ok

  defp ensure_cancellable(_), do: {:error, :not_cancellable}
end
```
