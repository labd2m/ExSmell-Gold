# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `schedule_task/4`, `add_durations/2`, `format_duration/1`, `exceeds_budget?/2`, `split_duration/2`
- **Affected Function(s)**: All public functions in `Scheduling.TaskDurationManager`
- **Explanation**: Task and budget durations are modelled as plain `integer()` values (seconds) rather than a `%Duration{seconds: non_neg_integer()}` struct with named helpers. This means the unit is purely implicit — any integer could be passed, values could represent minutes or milliseconds by mistake — and formatting, arithmetic, and comparison logic is scattered as standalone helpers with no attachment to the concept of duration.

## Code

```elixir
defmodule Scheduling.TaskDurationManager do
  @moduledoc """
  Manages duration budgets and scheduling windows for background tasks,
  maintenance jobs, and customer-facing service bookings. All durations
  are stored internally as seconds.
  """

  require Logger

  @max_task_duration_seconds 86_400
  @min_task_duration_seconds 60

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because task duration is represented as a raw
  # VALIDATION: `integer()` (implicitly in seconds) rather than a
  # VALIDATION: `%Duration{seconds: non_neg_integer()}` struct. Every function
  # VALIDATION: accepts bare integers and the unit is enforced only by naming
  # VALIDATION: convention, making it trivially easy to pass a value in minutes
  # VALIDATION: or milliseconds and produce silently wrong scheduling results.
  @spec schedule_task(String.t(), String.t(), integer(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def schedule_task(task_id, task_type, duration_seconds, budget_seconds)
      when is_integer(duration_seconds) and is_integer(budget_seconds) do
    with :ok <- validate_duration(duration_seconds),
         false <- exceeds_budget?(duration_seconds, budget_seconds) do
      task = %{
        id: task_id,
        type: task_type,
        duration_seconds: duration_seconds,
        budget_seconds: budget_seconds,
        remaining_budget_seconds: budget_seconds - duration_seconds,
        human_duration: format_duration(duration_seconds),
        scheduled_at: DateTime.utc_now()
      }

      Logger.info(
        "Task #{task_id} scheduled: #{format_duration(duration_seconds)} " <>
          "(budget: #{format_duration(budget_seconds)})"
      )

      {:ok, task}
    else
      true ->
        {:error,
         "Duration #{format_duration(duration_seconds)} exceeds budget #{format_duration(budget_seconds)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec add_durations(integer(), integer()) :: integer()
  def add_durations(duration_a, duration_b)
      when is_integer(duration_a) and is_integer(duration_b) do
    duration_a + duration_b
  end

  @spec format_duration(integer()) :: String.t()
  def format_duration(total_seconds) when is_integer(total_seconds) do
    days = div(total_seconds, 86_400)
    remainder = rem(total_seconds, 86_400)
    hours = div(remainder, 3_600)
    remainder = rem(remainder, 3_600)
    minutes = div(remainder, 60)
    seconds = rem(remainder, 60)

    parts =
      [
        if(days > 0, do: "#{days}d", else: nil),
        if(hours > 0, do: "#{hours}h", else: nil),
        if(minutes > 0, do: "#{minutes}m", else: nil),
        if(seconds > 0 or total_seconds == 0, do: "#{seconds}s", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " ")
  end

  @spec exceeds_budget?(integer(), integer()) :: boolean()
  def exceeds_budget?(duration_seconds, budget_seconds) do
    duration_seconds > budget_seconds
  end

  @spec split_duration(integer(), pos_integer()) :: list(integer())
  def split_duration(total_seconds, parts) when parts > 0 do
    base = div(total_seconds, parts)
    remainder = rem(total_seconds, parts)

    Enum.map(1..parts, fn i ->
      if i == 1, do: base + remainder, else: base
    end)
  end

  @spec total_scheduled_duration(list(map())) :: integer()
  def total_scheduled_duration(tasks) do
    Enum.reduce(tasks, 0, fn task, acc ->
      add_durations(acc, task.duration_seconds)
    end)
  end

  @spec from_minutes(integer()) :: integer()
  def from_minutes(minutes) when is_integer(minutes), do: minutes * 60

  @spec from_hours(integer()) :: integer()
  def from_hours(hours) when is_integer(hours), do: hours * 3_600

  @spec to_minutes(integer()) :: float()
  def to_minutes(seconds) when is_integer(seconds), do: seconds / 60.0

  @spec to_hours(integer()) :: float()
  def to_hours(seconds) when is_integer(seconds), do: seconds / 3_600.0
  # VALIDATION: SMELL END

  defp validate_duration(seconds) do
    cond do
      seconds < @min_task_duration_seconds ->
        {:error,
         "Duration #{format_duration(seconds)} is below minimum #{format_duration(@min_task_duration_seconds)}"}

      seconds > @max_task_duration_seconds ->
        {:error,
         "Duration #{format_duration(seconds)} exceeds maximum #{format_duration(@max_task_duration_seconds)}"}

      true ->
        :ok
    end
  end
end
```
