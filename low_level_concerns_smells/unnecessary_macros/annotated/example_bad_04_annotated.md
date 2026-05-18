# Annotated Example 04 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro days_between/2` inside `Scheduling.DateUtils`
- **Affected function(s):** `days_between/2`
- **Short explanation:** The macro computes the difference in days between two `Date` structs using only standard runtime operations. There is nothing to evaluate at compile time; a plain function is the correct abstraction here.

---

```elixir
defmodule Scheduling.DateUtils do
  @moduledoc """
  Date and time utility helpers for the scheduling subsystem.
  Used by appointment booking, resource allocation, and report generation.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because days_between/2 only calls Date.diff/2,
  # a standard runtime library function. There is no AST transformation or
  # compile-time benefit; a def function is the appropriate tool here.
  defmacro days_between(date_a, date_b) do
    quote do
      Date.diff(unquote(date_b), unquote(date_a))
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the start and end dates of the ISO week containing the given date.
  """
  @spec week_bounds(Date.t()) :: {Date.t(), Date.t()}
  def week_bounds(%Date{} = date) do
    day_of_week = Date.day_of_week(date)
    start_of_week = Date.add(date, -(day_of_week - 1))
    end_of_week = Date.add(start_of_week, 6)
    {start_of_week, end_of_week}
  end

  @doc """
  Returns true if the given date falls on a weekend.
  """
  @spec weekend?(Date.t()) :: boolean()
  def weekend?(%Date{} = date) do
    Date.day_of_week(date) in [6, 7]
  end

  @doc """
  Returns a list of all business days (Mon–Fri) within the given range, inclusive.
  """
  @spec business_days_in_range(Date.t(), Date.t()) :: list(Date.t())
  def business_days_in_range(%Date{} = from, %Date{} = to) do
    Date.range(from, to)
    |> Enum.reject(&weekend?/1)
  end
end

defmodule Scheduling.AppointmentService do
  @moduledoc """
  Manages appointment lifecycle: creation, rescheduling, and cancellation.
  Enforces booking policies such as minimum advance notice and slot duration.
  """

  require Scheduling.DateUtils

  alias Scheduling.DateUtils

  @min_advance_days 1
  @max_advance_days 60
  @slot_duration_minutes 30

  @doc """
  Validates whether a requested appointment date is within the bookable window.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_booking_date(Date.t()) :: :ok | {:error, String.t()}
  def validate_booking_date(%Date{} = requested_date) do
    today = Date.utc_today()
    diff = DateUtils.days_between(today, requested_date)

    cond do
      diff < @min_advance_days ->
        {:error, "Appointments must be booked at least #{@min_advance_days} day(s) in advance"}

      diff > @max_advance_days ->
        {:error, "Appointments cannot be booked more than #{@max_advance_days} days ahead"}

      DateUtils.weekend?(requested_date) ->
        {:error, "Appointments are not available on weekends"}

      true ->
        :ok
    end
  end

  @doc """
  Returns all available slots on a given date, excluding already-booked times.
  """
  @spec available_slots(Date.t(), list(Time.t())) :: list(Time.t())
  def available_slots(%Date{} = date, booked_times) do
    all_slots =
      Enum.map(0..15, fn i ->
        Time.add(~T[08:00:00], i * @slot_duration_minutes * 60, :second)
      end)

    if DateUtils.weekend?(date) do
      []
    else
      Enum.reject(all_slots, fn slot -> slot in booked_times end)
    end
  end

  @doc """
  Returns a summary of upcoming appointments within the next N days.
  """
  @spec upcoming_summary(list(map()), non_neg_integer()) :: list(map())
  def upcoming_summary(appointments, within_days) do
    today = Date.utc_today()
    cutoff = Date.add(today, within_days)

    appointments
    |> Enum.filter(fn appt ->
      appt_date = DateTime.to_date(appt.scheduled_at)
      DateUtils.days_between(today, appt_date) in 0..within_days and
        Date.compare(appt_date, cutoff) != :gt
    end)
    |> Enum.sort_by(& &1.scheduled_at, DateTime)
  end
end
```
