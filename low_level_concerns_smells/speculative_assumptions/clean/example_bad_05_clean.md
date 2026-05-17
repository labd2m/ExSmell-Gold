```elixir
defmodule Scheduling.RecurrenceParser do
  @moduledoc """
  Parses human-readable recurrence rule strings into internal scheduling
  intervals used by the job scheduler to compute next-run timestamps.

  Accepted format examples:
    "every_5_minutes"
    "every_2_hours"
    "every_1_day"
    "every_3_weeks"
  """

  require Logger

  @unit_map %{
    "minute"  => :minute,
    "minutes" => :minute,
    "hour"    => :hour,
    "hours"   => :hour,
    "day"     => :day,
    "days"    => :day,
    "week"    => :week,
    "weeks"   => :week
  }

  @doc """
  Parses a recurrence string and returns a `{quantity, unit}` tuple, e.g.
  `{5, :minute}`, `{2, :hour}`, `{1, :day}`.
  """

  def parse_schedule_interval(rule) when is_binary(rule) do
    parts = String.split(rule, "_")

    case parts do
      ["every", qty_str | rest] ->
        unit_str = Enum.join(rest, "_")

        with {qty, ""} <- Integer.parse(qty_str),
             {:ok, unit} <- resolve_unit(unit_str) do
          {qty, unit}
        else
          _ ->
            Logger.warning("RecurrenceParser: unrecognised rule #{inspect(rule)}, defaulting to 1 day")
            {1, :day}
        end

      _ ->
        Logger.warning("RecurrenceParser: malformed rule #{inspect(rule)}, defaulting to 1 day")
        {1, :day}
    end
  end

  @doc """
  Computes the next run datetime from a base datetime and a parsed interval.
  """
  def next_run(base_dt, {qty, :minute}), do: Timex.shift(base_dt, minutes: qty)
  def next_run(base_dt, {qty, :hour}),   do: Timex.shift(base_dt, hours: qty)
  def next_run(base_dt, {qty, :day}),    do: Timex.shift(base_dt, days: qty)
  def next_run(base_dt, {qty, :week}),   do: Timex.shift(base_dt, weeks: qty)

  def next_run(_base_dt, {_qty, unknown_unit}) do
    raise ArgumentError, "unsupported schedule unit: #{inspect(unknown_unit)}"
  end

  @doc """
  Returns all valid unit strings accepted by the parser.
  """
  def valid_units, do: Map.keys(@unit_map)

  defp resolve_unit(unit_str) do
    case Map.fetch(@unit_map, unit_str) do
      {:ok, unit} -> {:ok, unit}
      :error      -> {:error, {:unknown_unit, unit_str}}
    end
  end

  @doc """
  Returns true if the given recurrence rule string is in a recognised format.
  """
  def valid_rule?(rule) when is_binary(rule) do
    case parse_schedule_interval(rule) do
      {qty, unit} when is_integer(qty) and qty > 0 and unit in [:minute, :hour, :day, :week] -> true
      _ -> false
    end
  end

  def valid_rule?(_), do: false
end
```
