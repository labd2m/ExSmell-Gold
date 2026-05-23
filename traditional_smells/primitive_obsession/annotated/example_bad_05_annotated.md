# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `book_slot/4`, `overlaps?/4`, `available_slots/3`, `slot_duration_minutes/2`
- **Affected Function(s)**: All public functions in `Scheduling.AppointmentService`
- **Explanation**: A time slot is represented by two raw `String.t()` values (`start_time` and `end_time` in ISO-8601 format) plus a `String.t()` timezone, all passed separately to every function, instead of being encapsulated in a `%TimeSlot{}` struct. This scatters parsing and comparison logic, allows callers to pass start/end in the wrong order silently, and repeats timezone handling throughout the module.

## Code

```elixir
defmodule Scheduling.AppointmentService do
  @moduledoc """
  Manages appointment booking, availability checking, and slot
  overlap detection for the scheduling subsystem. All times are
  stored and communicated as ISO-8601 strings with an explicit
  timezone identifier.
  """

  require Logger

  @slot_interval_minutes 30
  @max_advance_booking_days 90

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because a time slot is modelled as two raw
  # VALIDATION: `String.t()` ISO-8601 timestamps and a separate `String.t()`
  # VALIDATION: timezone identifier, instead of a single `%TimeSlot{}` struct.
  # VALIDATION: Every function must accept three related primitives, parse them
  # VALIDATION: independently, and risk silently accepting swapped start/end values.
  @spec book_slot(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def book_slot(provider_id, start_time, end_time, timezone) do
    with {:ok, start_dt} <- parse_datetime(start_time, timezone),
         {:ok, end_dt} <- parse_datetime(end_time, timezone),
         :ok <- validate_ordering(start_dt, end_dt),
         :ok <- validate_advance_booking(start_dt),
         false <- slot_already_taken?(provider_id, start_time, end_time, timezone) do
      appointment = %{
        id: generate_id(),
        provider_id: provider_id,
        start_time: start_time,
        end_time: end_time,
        timezone: timezone,
        duration_minutes: slot_duration_minutes(start_time, end_time),
        booked_at: DateTime.utc_now()
      }

      Logger.info(
        "Appointment #{appointment.id} booked for provider #{provider_id}: " <>
          "#{start_time} – #{end_time} (#{timezone})"
      )

      {:ok, appointment}
    else
      true -> {:error, "Requested slot is already booked"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec overlaps?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  def overlaps?(start_a, end_a, start_b, end_b) do
    with {:ok, sa} <- parse_naive(start_a),
         {:ok, ea} <- parse_naive(end_a),
         {:ok, sb} <- parse_naive(start_b),
         {:ok, eb} <- parse_naive(end_b) do
      NaiveDateTime.compare(sa, eb) == :lt and NaiveDateTime.compare(ea, sb) == :gt
    else
      _ -> false
    end
  end

  @spec slot_duration_minutes(String.t(), String.t()) :: non_neg_integer()
  def slot_duration_minutes(start_time, end_time) do
    with {:ok, start_dt} <- parse_naive(start_time),
         {:ok, end_dt} <- parse_naive(end_time) do
      NaiveDateTime.diff(end_dt, start_dt, :second) |> div(60) |> max(0)
    else
      _ -> 0
    end
  end

  @spec available_slots(String.t(), String.t(), String.t()) :: list(map())
  def available_slots(provider_id, date_str, timezone) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        generate_candidate_slots(date, timezone)
        |> Enum.reject(fn {slot_start, slot_end} ->
          slot_already_taken?(provider_id, slot_start, slot_end, timezone)
        end)
        |> Enum.map(fn {slot_start, slot_end} ->
          %{
            start_time: slot_start,
            end_time: slot_end,
            timezone: timezone,
            duration_minutes: @slot_interval_minutes
          }
        end)

      {:error, _} ->
        Logger.error("Invalid date format: #{date_str}")
        []
    end
  end
  # VALIDATION: SMELL END

  defp generate_candidate_slots(date, timezone) do
    start_hour = 9
    end_hour = 17

    for hour <- start_hour..(end_hour - 1),
        minute <- [0, 30] do
      slot_start =
        NaiveDateTime.new!(date, Time.new!(hour, minute, 0))
        |> NaiveDateTime.to_iso8601()

      slot_end =
        NaiveDateTime.new!(date, Time.new!(hour, minute + @slot_interval_minutes, 0))
        |> NaiveDateTime.to_iso8601()

      {slot_start, slot_end}
    end
  rescue
    _ -> []
  end

  defp slot_already_taken?(provider_id, _start, _end, _tz) do
    # Stub: in production this queries the bookings table
    Logger.debug("Checking availability for provider #{provider_id}")
    false
  end

  defp parse_datetime(iso_string, _timezone) do
    case NaiveDateTime.from_iso8601(iso_string) do
      {:ok, ndt} -> {:ok, ndt}
      {:error, _} -> {:error, "Invalid datetime format: #{iso_string}"}
    end
  end

  defp parse_naive(iso_string) do
    NaiveDateTime.from_iso8601(iso_string)
  end

  defp validate_ordering(start_dt, end_dt) do
    if NaiveDateTime.compare(start_dt, end_dt) == :lt do
      :ok
    else
      {:error, "Start time must be before end time"}
    end
  end

  defp validate_advance_booking(start_dt) do
    today = Date.utc_today()
    limit = Date.add(today, @max_advance_booking_days)
    slot_date = NaiveDateTime.to_date(start_dt)

    if Date.compare(slot_date, limit) != :gt do
      :ok
    else
      {:error, "Slot is too far in the future (max #{@max_advance_booking_days} days ahead)"}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
```
