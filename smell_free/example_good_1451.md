```elixir
defmodule Scheduling.RecurringSchedule do
  @moduledoc """
  Computes occurrences of a recurring schedule expressed in a named
  time zone. Handles DST transitions by working in wall-clock time
  and converting to UTC only for storage and comparison.
  """

  @type frequency :: :daily | :weekly | :monthly | :yearly

  @type schedule :: %{
          starts_at: NaiveDateTime.t(),
          frequency: frequency(),
          interval: pos_integer(),
          time_zone: String.t(),
          until: Date.t() | nil,
          count: pos_integer() | nil
        }

  @type occurrence :: %{wall_time: NaiveDateTime.t(), utc_time: DateTime.t()}

  @spec next_occurrences(schedule(), pos_integer()) ::
          {:ok, [occurrence()]} | {:error, atom()}
  def next_occurrences(schedule, limit) when is_integer(limit) and limit > 0 do
    with :ok <- validate_schedule(schedule),
         {:ok, now_utc} <- current_utc() do
      occurrences =
        schedule
        |> generate_stream()
        |> Stream.filter(&after_now?(&1, now_utc, schedule.time_zone))
        |> Stream.take(limit)
        |> Enum.to_list()

      {:ok, occurrences}
    end
  end

  @spec occurrences_between(schedule(), Date.t(), Date.t()) ::
          {:ok, [occurrence()]} | {:error, atom()}
  def occurrences_between(schedule, from_date, to_date) do
    with :ok <- validate_schedule(schedule) do
      occurrences =
        schedule
        |> generate_stream()
        |> Stream.take_while(&before_date?(&1, to_date))
        |> Stream.filter(&on_or_after_date?(&1, from_date))
        |> Enum.to_list()

      {:ok, occurrences}
    end
  end

  @spec generate_stream(schedule()) :: Enumerable.t()
  defp generate_stream(schedule) do
    Stream.unfold(schedule.starts_at, fn current ->
      if schedule_ended?(current, schedule) do
        nil
      else
        occurrence = to_occurrence(current, schedule.time_zone)
        next = advance(current, schedule.frequency, schedule.interval)
        {occurrence, next}
      end
    end)
  end

  @spec advance(NaiveDateTime.t(), frequency(), pos_integer()) :: NaiveDateTime.t()
  defp advance(dt, :daily, interval), do: NaiveDateTime.add(dt, interval * 86_400, :second)
  defp advance(dt, :weekly, interval), do: NaiveDateTime.add(dt, interval * 7 * 86_400, :second)

  defp advance(%{year: y, month: m, day: d} = dt, :monthly, interval) do
    total_months = y * 12 + (m - 1) + interval
    new_year = div(total_months, 12)
    new_month = rem(total_months, 12) + 1
    new_day = min(d, :calendar.last_day_of_the_month(new_year, new_month))
    %{dt | year: new_year, month: new_month, day: new_day}
  end

  defp advance(%{year: y} = dt, :yearly, interval), do: %{dt | year: y + interval}

  @spec to_occurrence(NaiveDateTime.t(), String.t()) :: occurrence()
  defp to_occurrence(wall_time, time_zone) do
    utc_time =
      case DateTime.from_naive(wall_time, time_zone) do
        {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
        {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
        {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      end

    %{wall_time: wall_time, utc_time: utc_time}
  end

  @spec after_now?(occurrence(), DateTime.t(), String.t()) :: boolean()
  defp after_now?(occurrence, now_utc, _tz) do
    DateTime.compare(occurrence.utc_time, now_utc) == :gt
  end

  @spec before_date?(occurrence(), Date.t()) :: boolean()
  defp before_date?(occurrence, date) do
    NaiveDateTime.to_date(occurrence.wall_time) <= date
  end

  @spec on_or_after_date?(occurrence(), Date.t()) :: boolean()
  defp on_or_after_date?(occurrence, date) do
    NaiveDateTime.to_date(occurrence.wall_time) >= date
  end

  @spec schedule_ended?(NaiveDateTime.t(), schedule()) :: boolean()
  defp schedule_ended?(_current, %{until: nil, count: nil}), do: false

  defp schedule_ended?(current, %{until: until}) when not is_nil(until) do
    NaiveDateTime.to_date(current) > until
  end

  defp schedule_ended?(_current, _schedule), do: false

  @spec validate_schedule(schedule()) :: :ok | {:error, atom()}
  defp validate_schedule(%{interval: interval}) when interval < 1, do: {:error, :invalid_interval}
  defp validate_schedule(%{time_zone: tz}) when not is_binary(tz), do: {:error, :invalid_time_zone}
  defp validate_schedule(_), do: :ok

  @spec current_utc() :: {:ok, DateTime.t()}
  defp current_utc, do: {:ok, DateTime.utc_now()}
end
```
