```elixir
defmodule Scheduling.TimeUtils do
  @moduledoc """
  Time zone and datetime utilities for the scheduling context.
  Used when persisting or comparing datetimes that arrive in local time.
  """

  @default_timezone "America/New_York"

  defmacro to_utc(naive_dt) do
    quote do
      DateTime.from_naive!(unquote(naive_dt), "Etc/UTC")
    end
  end

  @doc """
  Returns the start of the day (00:00:00) for the given date.
  """
  @spec start_of_day(Date.t()) :: NaiveDateTime.t()
  def start_of_day(%Date{} = date) do
    NaiveDateTime.new!(date, ~T[00:00:00])
  end

  @doc """
  Returns the end of the day (23:59:59) for the given date.
  """
  @spec end_of_day(Date.t()) :: NaiveDateTime.t()
  def end_of_day(%Date{} = date) do
    NaiveDateTime.new!(date, ~T[23:59:59])
  end

  @doc """
  Returns the number of minutes between two datetimes, always non-negative.
  """
  @spec minutes_between(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def minutes_between(%DateTime{} = from, %DateTime{} = to) do
    abs(DateTime.diff(to, from, :second)) |> div(60)
  end

  @doc """
  Returns the default scheduling timezone.
  """
  @spec default_timezone() :: String.t()
  def default_timezone, do: @default_timezone
end

defmodule Scheduling.BookingRepository do
  @moduledoc """
  Handles persistence operations for bookings, including filtering by date range
  and resolving datetime conflicts with existing appointments.
  """

  require Scheduling.TimeUtils

  alias Scheduling.TimeUtils

  @doc """
  Filters a list of booking records to those whose scheduled time falls within
  the given date range (inclusive), converting local naive datetimes to UTC.
  """
  @spec filter_by_date_range(list(map()), Date.t(), Date.t()) :: list(map())
  def filter_by_date_range(bookings, from_date, to_date) do
    range_start = TimeUtils.to_utc(TimeUtils.start_of_day(from_date))
    range_end = TimeUtils.to_utc(TimeUtils.end_of_day(to_date))

    Enum.filter(bookings, fn booking ->
      scheduled = booking.scheduled_at
      DateTime.compare(scheduled, range_start) != :lt and
        DateTime.compare(scheduled, range_end) != :gt
    end)
  end

  @doc """
  Checks whether a proposed booking slot conflicts with any existing booking.
  A conflict is defined as an overlap within the slot's duration window.
  """
  @spec conflicts?(map(), list(map()), pos_integer()) :: boolean()
  def conflicts?(%{scheduled_at: proposed_dt}, existing_bookings, duration_minutes) do
    proposed_end = DateTime.add(proposed_dt, duration_minutes * 60, :second)

    Enum.any?(existing_bookings, fn booking ->
      booking_end = DateTime.add(booking.scheduled_at, booking.duration_minutes * 60, :second)

      DateTime.compare(proposed_dt, booking_end) == :lt and
        DateTime.compare(proposed_end, booking.scheduled_at) == :gt
    end)
  end

  @doc """
  Groups bookings by the date portion of their scheduled_at datetime.
  Returns a map of `%Date{}` => list(booking).
  """
  @spec group_by_date(list(map())) :: map()
  def group_by_date(bookings) do
    Enum.group_by(bookings, fn booking ->
      DateTime.to_date(booking.scheduled_at)
    end)
  end

  @doc """
  Returns all bookings for a specific practitioner, sorted ascending by time.
  """
  @spec for_practitioner(list(map()), String.t()) :: list(map())
  def for_practitioner(bookings, practitioner_id) do
    bookings
    |> Enum.filter(&(&1.practitioner_id == practitioner_id))
    |> Enum.sort_by(& &1.scheduled_at, DateTime)
  end
end
```
