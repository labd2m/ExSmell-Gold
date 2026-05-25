# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `RecurrenceEngine` module — functions `next_occurrence/2`, `occurrences_per_year/1`, and `recurrence_label/1`
- **Affected functions:** `next_occurrence/2`, `occurrences_per_year/1`, `recurrence_label/1`
- **Short explanation:** The same `case recurrence` branching over `:daily`, `:weekly`, `:biweekly`, and `:monthly` is duplicated in three functions. Adding a new recurrence type requires updating all three case blocks independently, which is the Switch Statements smell.

---

```elixir
defmodule RecurrenceEngine do
  @moduledoc """
  Computes scheduling recurrences for calendar events, maintenance windows,
  billing cycles, and automated tasks in the scheduling subsystem.
  """

  require Logger

  @recurrence_types [:daily, :weekly, :biweekly, :monthly]

  def valid_recurrence_types, do: @recurrence_types

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over recurrence
  # (:daily, :weekly, :biweekly, :monthly) is duplicated in next_occurrence/2,
  # occurrences_per_year/1, and recurrence_label/1. A new recurrence type forces
  # changes to all three functions independently.

  @doc """
  Returns the next occurrence date after `from_date` for the given recurrence type.
  """
  def next_occurrence(%{recurrence: recurrence}, %Date{} = from_date) do
    case recurrence do
      :daily -> Date.add(from_date, 1)
      :weekly -> Date.add(from_date, 7)
      :biweekly -> Date.add(from_date, 14)
      :monthly -> Date.new!(from_date.year, from_date.month, from_date.day) |> shift_month(1)
      _ -> Date.add(from_date, 7)
    end
  end

  @doc """
  Returns the approximate number of occurrences per year for the given recurrence type.
  Used for billing projections and capacity planning.
  """
  def occurrences_per_year(%{recurrence: recurrence}) do
    case recurrence do
      :daily -> 365
      :weekly -> 52
      :biweekly -> 26
      :monthly -> 12
      _ -> 52
    end
  end

  @doc """
  Returns a human-readable label for the recurrence type, used in the scheduling
  UI and email confirmations.
  """
  def recurrence_label(%{recurrence: recurrence}) do
    case recurrence do
      :daily -> "Every day"
      :weekly -> "Every week"
      :biweekly -> "Every two weeks"
      :monthly -> "Every month"
      _ -> "Custom recurrence"
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Generates a list of occurrence dates between `start_date` and `end_date`.
  """
  def occurrences_between(%{recurrence: _recurrence} = schedule, start_date, end_date) do
    Stream.iterate(start_date, fn current ->
      next_occurrence(schedule, current)
    end)
    |> Stream.take_while(fn date -> Date.compare(date, end_date) != :gt end)
    |> Enum.to_list()
  end

  @doc """
  Projects the next N occurrence dates starting from today.
  """
  def upcoming_occurrences(%{recurrence: _recurrence} = schedule, count)
      when is_integer(count) and count > 0 do
    today = Date.utc_today()

    Stream.iterate(today, fn current ->
      next_occurrence(schedule, current)
    end)
    |> Stream.drop(1)
    |> Enum.take(count)
  end

  @doc """
  Returns a scheduling summary including label, frequency, and next occurrence.
  """
  def schedule_summary(%{recurrence: _recurrence, start_date: start_date} = schedule) do
    next = next_occurrence(schedule, start_date)
    per_year = occurrences_per_year(schedule)
    label = recurrence_label(schedule)

    %{
      recurrence: schedule.recurrence,
      label: label,
      occurrences_per_year: per_year,
      next_occurrence: next,
      start_date: start_date
    }
  end

  @doc """
  Validates that a schedule struct has valid recurrence and start_date fields.
  """
  def validate(%{recurrence: recurrence, start_date: %Date{}} = schedule)
      when recurrence in @recurrence_types do
    {:ok, schedule}
  end

  def validate(%{recurrence: unknown}) when unknown not in @recurrence_types do
    {:error, {:unknown_recurrence, unknown}}
  end

  def validate(_), do: {:error, :invalid_schedule}

  @doc """
  Calculates the estimated annual cost of a recurring schedule given a per-occurrence fee.
  """
  def annual_cost_estimate(%{} = schedule, cost_per_occurrence)
      when is_number(cost_per_occurrence) do
    per_year = occurrences_per_year(schedule)
    Float.round(per_year * cost_per_occurrence, 2)
  end

  # ---- Private helpers ----

  defp shift_month(%Date{year: year, month: 12} = _date, 1) do
    Date.new!(year + 1, 1, 1)
  end

  defp shift_month(%Date{year: year, month: month, day: day}, 1) do
    target_month = month + 1
    days_in_target = Date.days_in_month(Date.new!(year, target_month, 1))
    clamped_day = min(day, days_in_target)
    Date.new!(year, target_month, clamped_day)
  end
end
```
