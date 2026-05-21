## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `extract_attendee_ids/1` — the `Enum.map(attendees, ...)` call
- **Affected function(s):** `Scheduling.MeetingCoordinator.extract_attendee_ids/1`
- **Short explanation:** `Enum.map/2` dispatches through the `Enumerable` protocol on `attendees`. No guard clause restricts `attendees` to types implementing `Enumerable`. Passing an integer, atom, float, binary, or PID raises `Protocol.UndefinedError` at runtime with no useful diagnostic for the caller.

```elixir
defmodule Scheduling.MeetingCoordinator do
  @moduledoc """
  Coordinates meeting scheduling: availability checks, attendee resolution,
  calendar slot booking, and conflict detection for internal scheduling workflows.
  """

  alias Scheduling.{Calendar, Attendee, Room, ConflictChecker}

  @default_duration_minutes 30
  @buffer_minutes 5

  def schedule_meeting(organizer_id, title, start_time, opts \\ []) do
    duration = Keyword.get(opts, :duration_minutes, @default_duration_minutes)
    attendees = Keyword.get(opts, :attendees, [])
    room_preference = Keyword.get(opts, :room, nil)

    end_time = DateTime.add(start_time, duration * 60, :second)

    with {:ok, attendee_ids} <- extract_attendee_ids(attendees),
         :ok <- ConflictChecker.check_all(attendee_ids, start_time, end_time),
         {:ok, room} <- resolve_room(room_preference, attendee_ids, start_time, end_time),
         {:ok, event} <-
           Calendar.create_event(%{
             organizer_id: organizer_id,
             title: title,
             start_time: start_time,
             end_time: end_time,
             attendee_ids: attendee_ids,
             room_id: room && room.id,
             buffer_after_minutes: @buffer_minutes
           }) do
      notify_attendees(event, attendee_ids)
      {:ok, event}
    end
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because `Enum.map/2` uses the `Enumerable` protocol on
  # VALIDATION: `attendees`. The function has no guard clause restricting `attendees` to
  # VALIDATION: types that implement `Enumerable` (e.g., list, map, range, MapSet).
  # VALIDATION: Passing an integer, atom, float, binary string, or PID causes a
  # VALIDATION: `Protocol.UndefinedError` at runtime with no meaningful context for the
  # VALIDATION: caller to understand what went wrong or which argument was invalid.
  def extract_attendee_ids(attendees) do
    ids =
      Enum.map(attendees, fn
        %Attendee{id: id} -> id
        id when is_binary(id) -> id
        id when is_integer(id) -> id
      end)

    if Enum.any?(ids, &is_nil/1) do
      {:error, :invalid_attendee_in_list}
    else
      {:ok, ids}
    end
  end
  # VALIDATION: SMELL END

  def resolve_room(nil, attendee_ids, start_time, end_time) do
    capacity_needed = length(attendee_ids) + 1
    Room.find_available(capacity_needed, start_time, end_time)
  end

  def resolve_room(room_id, _attendee_ids, start_time, end_time) do
    with {:ok, room} <- Room.fetch(room_id),
         :ok <- Room.check_availability(room, start_time, end_time) do
      {:ok, room}
    end
  end

  def cancel_meeting(event_id, reason \\ "cancelled") do
    with {:ok, event} <- Calendar.fetch_event(event_id),
         :ok <- Calendar.cancel_event(event_id, reason) do
      notify_cancellation(event, reason)
      :ok
    end
  end

  def reschedule_meeting(event_id, new_start_time, opts \\ []) do
    duration = Keyword.get(opts, :duration_minutes, @default_duration_minutes)
    new_end_time = DateTime.add(new_start_time, duration * 60, :second)

    with {:ok, event} <- Calendar.fetch_event(event_id),
         :ok <- ConflictChecker.check_all(event.attendee_ids, new_start_time, new_end_time),
         {:ok, updated} <- Calendar.update_event(event_id, %{start_time: new_start_time, end_time: new_end_time}) do
      notify_reschedule(updated)
      {:ok, updated}
    end
  end

  def upcoming_meetings(organizer_id, days_ahead \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), days_ahead * 86_400, :second)
    Calendar.list_events(organizer_id, from: DateTime.utc_now(), to: cutoff)
  end

  defp notify_attendees(event, attendee_ids) do
    Enum.each(attendee_ids, fn id ->
      Attendee.notify(id, :meeting_scheduled, event)
    end)
  end

  defp notify_cancellation(event, reason) do
    Enum.each(event.attendee_ids, fn id ->
      Attendee.notify(id, :meeting_cancelled, %{event: event, reason: reason})
    end)
  end

  defp notify_reschedule(event) do
    Enum.each(event.attendee_ids, fn id ->
      Attendee.notify(id, :meeting_rescheduled, event)
    end)
  end
end
```
