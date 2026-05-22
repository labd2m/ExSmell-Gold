```elixir
defmodule Scheduling.SlotHelpers do
  @moduledoc """
  Pure time-slot arithmetic helpers: overlap detection, duration computation,
  and working-hours boundary checks.
  """

  def slots_overlap?(%{start: s1, end: e1}, %{start: s2, end: e2}) do
    DateTime.compare(s1, e2) == :lt and DateTime.compare(s2, e1) == :lt
  end

  def slot_duration_minutes(%{start: start, end: stop}) do
    DateTime.diff(stop, start, :second) |> div(60)
  end

  def within_working_hours?(%{start: start, end: stop}, %{open: open_h, close: close_h}) do
    start.hour >= open_h and stop.hour <= close_h and stop.minute == 0 or
      (stop.hour == close_h and stop.minute == 0)
  end

  def slot_end(start, duration_minutes) when is_integer(duration_minutes) do
    DateTime.add(start, duration_minutes * 60, :second)
  end

  def build_slot(start, duration_minutes, provider_id) do
    %{
      start:       start,
      end:         slot_end(start, duration_minutes),
      provider_id: provider_id,
      duration:    duration_minutes
    }
  end

  def expand_daily_slots(%Date{} = date, provider_id, open_h, close_h, step_minutes) do
    base = DateTime.new!(date, Time.new!(open_h, 0, 0), "Etc/UTC")

    Stream.iterate(base, &DateTime.add(&1, step_minutes * 60, :second))
    |> Enum.take_while(fn dt -> dt.hour < close_h end)
    |> Enum.map(&build_slot(&1, step_minutes, provider_id))
  end

  defmacro __using__(_opts) do
    quote do
      import Scheduling.SlotHelpers
      alias Scheduling.CalendarSync

      @default_slot_minutes  30
      @booking_advance_days  60
    end
  end
end

defmodule Scheduling.CalendarSync do
  @moduledoc "Stub: synchronises confirmed bookings with external calendar providers."

  def push_event(booking) do
    IO.puts("[CalendarSync] Pushing booking #{booking.id} to external calendar")
    {:ok, %{external_id: "EXT-#{booking.id}"}}
  end

  def delete_event(booking_id) do
    IO.puts("[CalendarSync] Deleting external event for #{booking_id}")
    :ok
  end
end

defmodule Scheduling.BookingService do
  use Scheduling.SlotHelpers

  @moduledoc """
  Handles appointment booking, cancellation, and slot availability queries
  for a multi-provider scheduling system.
  """

  defstruct [:id, :user_id, :provider_id, :slot, :status, :notes, :booked_at]

  def book(%{user_id: uid, provider_id: pid, start: start} = params, existing_bookings) do
    slot = build_slot(start, params[:duration] || @default_slot_minutes, pid)
    max_start = DateTime.add(DateTime.utc_now(), @booking_advance_days * 86_400, :second)

    cond do
      DateTime.compare(start, DateTime.utc_now()) != :gt ->
        {:error, :slot_in_the_past}

      DateTime.compare(start, max_start) == :gt ->
        {:error, :too_far_in_advance}

      Enum.any?(existing_bookings, &slots_overlap?(&1.slot, slot)) ->
        {:error, :slot_unavailable}

      true ->
        booking = %__MODULE__{
          id:          generate_id(),
          user_id:     uid,
          provider_id: pid,
          slot:        slot,
          status:      :confirmed,
          notes:       params[:notes],
          booked_at:   DateTime.utc_now()
        }
        CalendarSync.push_event(booking)
        {:ok, booking}
    end
  end

  def cancel(%__MODULE__{status: :confirmed} = booking, reason) do
    CalendarSync.delete_event(booking.id)
    {:ok, %{booking | status: :cancelled}, reason}
  end

  def cancel(%__MODULE__{status: status}, _reason) do
    {:error, "Cannot cancel booking with status #{status}"}
  end

  def available_slots(provider_id, %Date{} = date, booked_slots) do
    all_slots = expand_daily_slots(date, provider_id, 9, 17, @default_slot_minutes)

    Enum.reject(all_slots, fn candidate ->
      Enum.any?(booked_slots, &slots_overlap?(&1, candidate))
    end)
  end

  def upcoming_for_user(user_id, all_bookings) do
    now = DateTime.utc_now()

    all_bookings
    |> Enum.filter(fn b ->
      b.user_id == user_id and
        b.status == :confirmed and
        DateTime.compare(b.slot.start, now) == :gt
    end)
    |> Enum.sort_by(fn b -> b.slot.start end, DateTime)
  end

  defp generate_id, do: "BKG-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
end
```
