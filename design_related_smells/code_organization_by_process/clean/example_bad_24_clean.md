```elixir
defmodule Scheduling.ConflictDetector do
  use GenServer

  @moduledoc """
  Detects and resolves scheduling conflicts for calendar events, resource
  bookings, and shift assignments. Used by the scheduling API and the
  availability check during booking flows.
  """

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns `true` if event `a` and event `b` overlap.
  Each event must have `:start_at` and `:end_at` `DateTime` fields.
  """
  def overlaps?(pid, event_a, event_b) do
    GenServer.call(pid, {:overlaps, event_a, event_b})
  end

  @doc """
  Returns all pairs of conflicting events from `events`.
  """
  def find_conflicts(pid, events) do
    GenServer.call(pid, {:find_conflicts, events})
  end

  @doc """
  Merges overlapping events into non-overlapping contiguous blocks.
  """
  def merge_overlapping(pid, events) do
    GenServer.call(pid, {:merge_overlapping, events})
  end

  @doc """
  Returns available time slots of `duration_minutes` within `window`
  that do not conflict with `booked_events`.
  """
  def free_slots(pid, window, booked_events, duration_minutes) do
    GenServer.call(pid, {:free_slots, window, booked_events, duration_minutes})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:overlaps, a, b}, _from, state) do
    result = DateTime.compare(a.start_at, b.end_at) == :lt and
             DateTime.compare(b.start_at, a.end_at) == :lt

    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_conflicts, events}, _from, state) do
    conflicts =
      for a <- events,
          b <- events,
          a.id < b.id,
          events_overlap?(a, b) do
        %{event_a: a.id, event_b: b.id, overlap_start: later(a.start_at, b.start_at),
          overlap_end: earlier(a.end_at, b.end_at)}
      end

    {:reply, {:ok, conflicts}, state}
  end

  @impl true
  def handle_call({:merge_overlapping, events}, _from, state) do
    sorted = Enum.sort_by(events, & &1.start_at, DateTime)

    merged =
      Enum.reduce(sorted, [], fn event, acc ->
        case acc do
          [] ->
            [event]

          [last | rest] ->
            if DateTime.compare(event.start_at, last.end_at) != :gt do
              new_end = later(last.end_at, event.end_at)
              [%{last | end_at: new_end} | rest]
            else
              [event | acc]
            end
        end
      end)
      |> Enum.reverse()

    {:reply, {:ok, merged}, state}
  end

  @impl true
  def handle_call({:free_slots, window, booked, duration_minutes}, _from, state) do
    duration_secs = duration_minutes * 60
    sorted_booked = Enum.sort_by(booked, & &1.start_at, DateTime)

    slots = find_free_slots(window.start_at, window.end_at, sorted_booked, duration_secs, [])

    {:reply, {:ok, slots}, state}
  end


  defp events_overlap?(a, b) do
    DateTime.compare(a.start_at, b.end_at) == :lt and
      DateTime.compare(b.start_at, a.end_at) == :lt
  end

  defp find_free_slots(cursor, window_end, [], duration, acc) do
    slot_end = DateTime.add(cursor, duration)
    if DateTime.compare(slot_end, window_end) != :gt do
      find_free_slots(DateTime.add(cursor, duration), window_end, [], duration, [
        %{start_at: cursor, end_at: slot_end} | acc
      ])
    else
      Enum.reverse(acc)
    end
  end

  defp find_free_slots(cursor, window_end, [next | rest], duration, acc) do
    slot_end = DateTime.add(cursor, duration)

    cond do
      DateTime.compare(slot_end, window_end) == :gt ->
        Enum.reverse(acc)

      DateTime.compare(slot_end, next.start_at) != :gt ->
        find_free_slots(
          DateTime.add(cursor, duration),
          window_end,
          [next | rest],
          duration,
          [%{start_at: cursor, end_at: slot_end} | acc]
        )

      true ->
        find_free_slots(next.end_at, window_end, rest, duration, acc)
    end
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
```
