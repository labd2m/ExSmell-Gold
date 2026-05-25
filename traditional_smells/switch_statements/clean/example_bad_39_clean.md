```elixir
defmodule RecurrenceEngine do
  @moduledoc """
  Calculates next occurrence dates and generates human-readable
  recurrence descriptions for scheduled tasks in a job-scheduling
  and recurring-billing platform.
  """

  alias RecurrenceEngine.{Schedule, Task}

  @type recurrence_type :: :daily | :weekly | :biweekly | :monthly | :quarterly

  @spec upcoming_occurrences(Schedule.t(), integer()) :: [Date.t()]
  def upcoming_occurrences(%Schedule{} = schedule, count) when count > 0 do
    Enum.reduce(1..count, [], fn _, acc ->
      last = List.last(acc) || schedule.start_date
      next = next_occurrence(last, schedule.recurrence)
      acc ++ [next]
    end)
  end

  @spec schedule_summary(Schedule.t()) :: map()
  def schedule_summary(%Schedule{} = schedule) do
    next = next_occurrence(schedule.last_run || schedule.start_date, schedule.recurrence)

    %{
      id: schedule.id,
      name: schedule.name,
      recurrence: schedule.recurrence,
      recurrence_label: recurrence_label(schedule.recurrence),
      next_run: next,
      last_run: schedule.last_run,
      active: schedule.active
    }
  end

  @spec due_now?([Schedule.t()]) :: [Schedule.t()]
  def due_now?(schedules) do
    today = Date.utc_today()

    Enum.filter(schedules, fn schedule ->
      last = schedule.last_run || Date.add(schedule.start_date, -1)
      next = next_occurrence(last, schedule.recurrence)
      Date.compare(next, today) != :gt
    end)
  end





  @spec next_occurrence(Date.t(), recurrence_type()) :: Date.t()
  def next_occurrence(from_date, recurrence) do
    case recurrence do
      :daily     -> Date.add(from_date, 1)
      :weekly    -> Date.add(from_date, 7)
      :biweekly  -> Date.add(from_date, 14)
      :monthly   -> shift_months(from_date, 1)
      :quarterly -> shift_months(from_date, 3)
    end
  end






  @spec recurrence_label(recurrence_type()) :: String.t()
  def recurrence_label(recurrence) do
    case recurrence do
      :daily     -> "Every day"
      :weekly    -> "Every week"
      :biweekly  -> "Every two weeks"
      :monthly   -> "Every month"
      :quarterly -> "Every quarter"
    end
  end


  @spec shift_months(Date.t(), integer()) :: Date.t()
  defp shift_months(%Date{year: year, month: month, day: day}, months) do
    total_months = year * 12 + (month - 1) + months
    new_year = div(total_months, 12)
    new_month = rem(total_months, 12) + 1
    max_day = Date.days_in_month(%Date{year: new_year, month: new_month, day: 1})
    %Date{year: new_year, month: new_month, day: min(day, max_day)}
  end

  @spec valid_recurrence?(atom()) :: boolean()
  def valid_recurrence?(r), do: r in [:daily, :weekly, :biweekly, :monthly, :quarterly]

  @spec build_schedule(map()) :: {:ok, Schedule.t()} | {:error, String.t()}
  def build_schedule(%{recurrence: r} = params) do
    if valid_recurrence?(r) do
      {:ok, struct!(Schedule, params)}
    else
      {:error, "invalid recurrence type: #{r}"}
    end
  end
end
```
