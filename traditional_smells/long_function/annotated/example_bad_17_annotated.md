# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Scheduling.RecurringEventManager.create/2`
- **Affected function(s):** `create/2`
- **Short explanation:** The `create/2` function handles recurrence rule parsing, occurrence date expansion, conflict checking across all generated occurrences, bulk event persistence, calendar invite generation, participant notification, and event series record creation all in a single body. Each phase is long enough and self-contained enough to deserve its own function.

---

```elixir
defmodule Scheduling.RecurringEventManager do
  @moduledoc """
  Creates recurring calendar events by expanding recurrence rules into
  individual occurrences and checking for scheduling conflicts.
  """

  alias Scheduling.{Event, EventSeries, Participant, CalendarInvite, Repo}
  alias Notifications.Dispatcher
  require Logger

  @max_occurrences 52
  @conflict_buffer_minutes 5

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `create/2` handles recurrence rule parsing,
  # VALIDATION: date expansion, overlap conflict checking, bulk event insertion,
  # VALIDATION: series record creation, invite generation, and participant notification
  # VALIDATION: all in one function that is far too long to be cohesive.
  def create(organizer_id, %{
        title: title,
        start_time: first_start,
        duration_minutes: duration,
        recurrence: recurrence,
        participants: participant_ids
      } = params) do

    Logger.info("Creating recurring event for organizer=#{organizer_id} rule=#{inspect(recurrence)}")

    # --- Validate and expand recurrence ---
    {interval_days, count} =
      case recurrence do
        %{frequency: :daily,   count: n} -> {1, min(n, @max_occurrences)}
        %{frequency: :weekly,  count: n} -> {7, min(n, @max_occurrences)}
        %{frequency: :monthly, count: n} -> {30, min(n, @max_occurrences)}
        _ -> {nil, 0}
      end

    if is_nil(interval_days) or count == 0 do
      {:error, :invalid_recurrence_rule}
    else
      # --- Expand occurrence start times ---
      occurrences =
        Enum.map(0..(count - 1), fn i ->
          start = DateTime.add(first_start, i * interval_days * 86_400, :second)
          finish = DateTime.add(start, duration * 60, :second)
          {start, finish}
        end)

      # --- Check for conflicts for each participant ---
      conflict_results =
        Enum.flat_map(occurrences, fn {occ_start, occ_end} ->
          buffered_start = DateTime.add(occ_start, -@conflict_buffer_minutes * 60, :second)
          buffered_end   = DateTime.add(occ_end, @conflict_buffer_minutes * 60, :second)

          Enum.flat_map(participant_ids, fn pid ->
            conflicts =
              Event
              |> Event.for_participant(pid)
              |> Event.overlapping(buffered_start, buffered_end)
              |> Event.active()
              |> Repo.all()

            Enum.map(conflicts, &{pid, occ_start, &1.id})
          end)
        end)

      if conflict_results != [] do
        Logger.warning("Conflicts detected: #{inspect(conflict_results)}")
        {:error, {:scheduling_conflicts, conflict_results}}
      else
        # --- Create event series record ---
        {:ok, series} =
          Repo.insert(EventSeries.changeset(%EventSeries{}, %{
            organizer_id: organizer_id,
            title: title,
            recurrence_rule: recurrence,
            occurrence_count: count,
            created_at: DateTime.utc_now()
          }))

        # --- Persist individual events ---
        events =
          Enum.map(occurrences, fn {occ_start, occ_end} ->
            {:ok, event} =
              Repo.insert(Event.changeset(%Event{}, %{
                series_id: series.id,
                organizer_id: organizer_id,
                title: title,
                start_at: occ_start,
                end_at: occ_end,
                duration_minutes: duration,
                location: Map.get(params, :location),
                description: Map.get(params, :description),
                status: :scheduled
              }))

            # Attach participants
            Enum.each(participant_ids, fn pid ->
              Repo.insert!(%Participant{event_id: event.id, user_id: pid, status: :invited})
            end)

            event
          end)

        # --- Generate and send calendar invites ---
        Enum.each(participant_ids, fn pid ->
          invite_payload = %{
            recipient_id: pid,
            series_id: series.id,
            title: title,
            first_occurrence: first_start,
            recurrence: recurrence,
            organizer_id: organizer_id
          }

          {:ok, _invite} =
            Repo.insert(CalendarInvite.changeset(%CalendarInvite{}, Map.put(invite_payload, :sent_at, DateTime.utc_now())))

          Dispatcher.dispatch(pid, %{
            type: "calendar_invite",
            payload: invite_payload
          })
        end)

        Logger.info("Recurring event series #{series.id} created with #{length(events)} occurrences")
        {:ok, %{series: series, events: events}}
      end
    end
  end
  # VALIDATION: SMELL END
end
```
