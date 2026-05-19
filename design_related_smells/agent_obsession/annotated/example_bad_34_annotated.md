# Code Smell: Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `SchedulerBooking`, `SchedulerConflict`, `SchedulerCalendar`, and `SchedulerReminder`
- **Affected functions:** `SchedulerBooking.book_slot/2`, `SchedulerConflict.has_conflict?/2`, `SchedulerCalendar.slots_for_day/2`, `SchedulerReminder.upcoming_reminders/2`
- **Short explanation:** Appointment scheduling state stored in an Agent is read and mutated from four different modules. Every module knows and depends on the internal shape of the shared state map, making the code brittle and hard to evolve.

---

```elixir
defmodule Scheduling.SchedulerBooking do
  @moduledoc """
  Creates and manages appointment bookings.
  """

  def start_link() do
    Agent.start_link(fn ->
      %{bookings: [], cancelled: [], reminders: []}
    end, name: __MODULE__)
  end

  def book_slot(pid, appointment) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because SchedulerBooking directly calls Agent.update/2
    # to add a booking, rather than routing all agent interactions through a single
    # owning module.
    Agent.update(pid, fn state ->
      entry = Map.merge(appointment, %{
        id: System.unique_integer([:positive]),
        booked_at: DateTime.utc_now(),
        status: :confirmed
      })
      %{state | bookings: [entry | state.bookings]}
    end)
    # VALIDATION: SMELL END
  end

  def cancel(pid, booking_id) do
    Agent.update(pid, fn state ->
      {to_cancel, remaining} =
        Enum.split_with(state.bookings, fn b -> b.id == booking_id end)

      cancelled = Enum.map(to_cancel, &Map.put(&1, :status, :cancelled))
      %{state | bookings: remaining, cancelled: state.cancelled ++ cancelled}
    end)
  end

  def get_booking(pid, booking_id) do
    Agent.get(pid, fn state ->
      Enum.find(state.bookings, &(&1.id == booking_id))
    end)
  end
end

defmodule Scheduling.SchedulerConflict do
  @moduledoc """
  Checks for booking conflicts before confirming appointments.
  """

  def has_conflict?(pid, proposed) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because SchedulerConflict directly reads Agent state
    # to perform conflict detection, independently knowing the structure of the bookings list.
    Agent.get(pid, fn state ->
      Enum.any?(state.bookings, fn existing ->
        existing.resource_id == proposed.resource_id and
          existing.status == :confirmed and
          ranges_overlap?(existing.start_time, existing.end_time, proposed.start_time, proposed.end_time)
      end)
    end)
    # VALIDATION: SMELL END
  end

  defp ranges_overlap?(s1, e1, s2, e2) do
    DateTime.compare(s1, e2) == :lt and DateTime.compare(s2, e1) == :lt
  end

  def conflicting_bookings(pid, resource_id) do
    Agent.get(pid, fn state ->
      state.bookings
      |> Enum.filter(&(&1.resource_id == resource_id and &1.status == :confirmed))
      |> Enum.sort_by(& &1.start_time, DateTime)
    end)
  end
end

defmodule Scheduling.SchedulerCalendar do
  @moduledoc """
  Renders the calendar view of bookings for a given day.
  """

  def slots_for_day(pid, date) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because SchedulerCalendar directly reads Agent state
    # to build its calendar view, introducing a third direct coupling to the shared agent.
    Agent.get(pid, fn state ->
      state.bookings
      |> Enum.filter(fn booking ->
        DateTime.to_date(booking.start_time) == date
      end)
      |> Enum.sort_by(& &1.start_time, DateTime)
    end)
    # VALIDATION: SMELL END
  end

  def available_slots(pid, date, all_slots) do
    booked = slots_for_day(pid, date) |> Enum.map(& &1.slot_key)
    Enum.reject(all_slots, &(&1 in booked))
  end
end

defmodule Scheduling.SchedulerReminder do
  @moduledoc """
  Sends reminders for upcoming appointments.
  """

  def upcoming_reminders(pid, within_minutes) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because SchedulerReminder directly reads Agent state
    # to determine which reminders to send, making it a fourth module directly coupled
    # to the agent's internal bookings structure.
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, within_minutes * 60, :second)

    Agent.get(pid, fn state ->
      Enum.filter(state.bookings, fn booking ->
        booking.status == :confirmed and
          DateTime.compare(booking.start_time, now) == :gt and
          DateTime.compare(booking.start_time, cutoff) != :gt
      end)
    end)
    # VALIDATION: SMELL END
  end

  def add_reminder(pid, booking_id, remind_at) do
    Agent.update(pid, fn state ->
      reminder = %{booking_id: booking_id, remind_at: remind_at, sent: false}
      %{state | reminders: [reminder | state.reminders]}
    end)
  end
end
```
