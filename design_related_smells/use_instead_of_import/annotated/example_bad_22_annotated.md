# Annotated Bad Example 22

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Scheduling.BookingService`, `use Scheduling.SlotHelpers` directive
**Affected Functions:** `book/2`, `cancel/2`, `available_slots/2`, `upcoming_for_user/2`
**Explanation:** `Scheduling.BookingService` uses `use Scheduling.SlotHelpers` to gain access to time-slot arithmetic and overlap-detection utilities. However, `SlotHelpers.__using__/1` also secretly injects an alias for `Scheduling.CalendarSync` and sets `@default_slot_minutes` and `@booking_advance_days` module attributes. A reader of `BookingService` cannot determine where `CalendarSync` or the module attributes come from without reading the library macro. A plain `import Scheduling.SlotHelpers` would have been transparent and sufficient.

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

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 injects alias Scheduling.CalendarSync
  # and two module attributes into any calling module, without the caller knowing.
  # These hidden injections make the module's actual dependency surface opaque.
  defmacro __using__(_opts) do
    quote do
      import Scheduling.SlotHelpers
      alias Scheduling.CalendarSync

      @default_slot_minutes  30
      @booking_advance_days  60
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
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
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Scheduling.SlotHelpers` expands
  # __using__/1 and silently makes alias Scheduling.CalendarSync, @default_slot_minutes,
  # and @booking_advance_days available in this module. None of these are declared
  # explicitly, so a reader must inspect SlotHelpers to understand the dependencies.
  # `import Scheduling.SlotHelpers` would be sufficient and transparent.
  use Scheduling.SlotHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

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
