# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `EventScheduler.default_duration_minutes/1` and `EventScheduler.calendar_color/1`
- **Affected functions:** `default_duration_minutes/1`, `calendar_color/1`
- **Short explanation:** The same `case` branching over event type (`:meeting`, `:interview`, `:training`, `:review`, `:social`) is duplicated in `default_duration_minutes/1` and `calendar_color/1`. Every new event type must be added to both functions.

---

```elixir
defmodule EventScheduler do
  @moduledoc """
  Manages calendar event creation, scheduling constraints, and
  display properties for a corporate scheduling application.
  Supports multiple event types with type-specific defaults.
  """

  alias EventScheduler.{Event, Participant, Room, ConflictChecker}

  @type event_type :: :meeting | :interview | :training | :review | :social

  @spec schedule_event(map()) :: {:ok, Event.t()} | {:error, term()}
  def schedule_event(params) do
    duration = Map.get(params, :duration_minutes, default_duration_minutes(params.type))

    event = %Event{
      title: params.title,
      type: params.type,
      organiser_id: params.organiser_id,
      start_at: params.start_at,
      end_at: DateTime.add(params.start_at, duration * 60, :second),
      room_id: params[:room_id],
      color: calendar_color(params.type)
    }

    with :ok <- ConflictChecker.check(event),
         :ok <- validate_participants(params[:participant_ids] || []),
         {:ok, saved} <- Event.insert(event) do
      {:ok, saved}
    end
  end

  @spec build_event_preview(atom(), DateTime.t()) :: map()
  def build_event_preview(event_type, start_at) do
    duration = default_duration_minutes(event_type)
    end_at = DateTime.add(start_at, duration * 60, :second)

    %{
      type: event_type,
      duration_minutes: duration,
      start_at: start_at,
      end_at: end_at,
      color: calendar_color(event_type)
    }
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `event_type`
  # also appears in `calendar_color/1` below. Both enumerate :meeting, :interview,
  # :training, :review, :social — adding a new event type requires touching both.
  @spec default_duration_minutes(event_type()) :: integer()
  def default_duration_minutes(event_type) do
    case event_type do
      :meeting   -> 60
      :interview -> 45
      :training  -> 120
      :review    -> 30
      :social    -> 90
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `event_type`
  # already appeared in `default_duration_minutes/1` above. The five event type
  # atoms are fully repeated, requiring parallel edits on any taxonomy change.
  @spec calendar_color(event_type()) :: String.t()
  def calendar_color(event_type) do
    case event_type do
      :meeting   -> "#4A90E2"
      :interview -> "#E2844A"
      :training  -> "#7ED321"
      :review    -> "#9B59B6"
      :social    -> "#F39C12"
    end
  end
  # VALIDATION: SMELL END

  @spec list_upcoming(String.t(), Date.t(), Date.t()) :: [Event.t()]
  def list_upcoming(organiser_id, from, to) do
    Event
    |> Event.for_organiser(organiser_id)
    |> Event.in_range(from, to)
    |> Event.order_by_start()
    |> Repo.all()
  end

  @spec cancel_event(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, String.t()}
  def cancel_event(%Event{} = event, reason) do
    if DateTime.compare(event.start_at, DateTime.utc_now()) == :gt do
      {:ok, %{event | status: :cancelled, cancellation_reason: reason}}
    else
      {:error, "cannot cancel a past event"}
    end
  end

  @spec validate_participants([String.t()]) :: :ok | {:error, String.t()}
  defp validate_participants(ids) when length(ids) > 50 do
    {:error, "maximum 50 participants per event"}
  end

  defp validate_participants(_ids), do: :ok
end
```
