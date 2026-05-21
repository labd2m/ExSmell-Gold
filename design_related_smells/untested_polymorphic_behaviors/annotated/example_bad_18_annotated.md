# Annotated Bad Example 18: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Scheduling.SlotFormatter.format_slot_key/2`
- **Affected function(s)**: `format_slot_key/2`
- **Short explanation**: The function builds a cache/index key from a `resource_id` argument by calling `to_string/1` on it. No guard clause restricts what types are accepted. While `String.Chars` is implemented for binaries, integers, and atoms, it is not implemented for maps, lists, or tuples. Passing such values will raise `Protocol.UndefinedError` at runtime. Furthermore, passing an integer silently produces a numeric key that may collide with a string key representing the same number, creating subtle cache-poisoning bugs in the scheduling system.

## Code

```elixir
defmodule Scheduling.SlotFormatter do
  @moduledoc """
  Provides slot formatting, key generation, and display utilities for the
  appointment scheduling system. Used by the booking API, the calendar UI,
  and the internal availability cache.
  """

  @key_namespace "slot"
  @display_time_format "%H:%M"
  @display_date_format "%d/%m/%Y"

  @doc """
  Builds a canonical cache/index key for a time slot.

  ## Parameters
    - `resource_id`: Identifier of the resource (room, doctor, staff member, etc.).
    - `slot_start`: A `DateTime` representing the start of the slot.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `to_string/1` is called on `resource_id`
  # without any guard clause. The `String.Chars` protocol is not implemented for
  # `Map`, `List`, or `Tuple`, so passing those types will raise
  # `Protocol.UndefinedError` at runtime. Additionally, passing an integer ID
  # (e.g., `42`) and a binary ID (e.g., `"42"`) will silently generate identical
  # keys, creating potential cache collisions in the scheduling layer. The function
  # should enforce `is_binary(resource_id)` or `is_integer(resource_id)` via a
  # guard clause to make type expectations explicit and testable.
  def format_slot_key(resource_id, %DateTime{} = slot_start) do
    ts = DateTime.to_unix(slot_start)
    "#{@key_namespace}:#{to_string(resource_id)}:#{ts}"
  end
  # VALIDATION: SMELL END

  @doc """
  Formats a slot start time for display in the booking UI.
  Returns a string such as `"14:30"`.
  """
  def format_slot_time(%DateTime{} = dt) do
    Calendar.strftime(dt, @display_time_format)
  end

  @doc """
  Formats a slot date for display.
  Returns a string such as `"23/07/2025"`.
  """
  def format_slot_date(%DateTime{} = dt) do
    Calendar.strftime(dt, @display_date_format)
  end

  @doc """
  Formats a full slot label combining date and time range.
  Returns a string such as `"23/07/2025 14:30 – 15:00"`.
  """
  def format_slot_label(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    date = format_slot_date(start_dt)
    start_time = format_slot_time(start_dt)
    end_time = format_slot_time(end_dt)
    "#{date} #{start_time} – #{end_time}"
  end

  @doc """
  Computes the duration in minutes between a slot's start and end times.
  """
  def slot_duration_minutes(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    diff_seconds = DateTime.diff(end_dt, start_dt, :second)
    div(diff_seconds, 60)
  end

  @doc """
  Returns whether a slot is in the past relative to the current UTC time.
  """
  def past_slot?(%DateTime{} = slot_start) do
    DateTime.compare(slot_start, DateTime.utc_now()) == :lt
  end

  @doc """
  Groups a flat list of slot maps by their date.
  Each map must contain a `:start_at` key with a `DateTime` value.
  """
  def group_by_date(slots) when is_list(slots) do
    slots
    |> Enum.sort_by(& &1.start_at, {:asc, DateTime})
    |> Enum.group_by(fn %{start_at: dt} -> DateTime.to_date(dt) end)
  end

  @doc """
  Filters a list of slots to only those available for booking.
  A slot is available if it has `status: :open` and is not in the past.
  """
  def available_slots(slots) when is_list(slots) do
    Enum.filter(slots, fn slot ->
      slot.status == :open and not past_slot?(slot.start_at)
    end)
  end

  @doc """
  Returns the human-readable label for a slot status.
  """
  def status_label(:open), do: "Available"
  def status_label(:booked), do: "Booked"
  def status_label(:blocked), do: "Unavailable"
  def status_label(:cancelled), do: "Cancelled"
  def status_label(:pending), do: "Pending Confirmation"
end
```
