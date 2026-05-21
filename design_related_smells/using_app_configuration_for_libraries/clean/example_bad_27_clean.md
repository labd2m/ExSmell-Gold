```elixir
defmodule CronParser do
  @moduledoc """
  Library for parsing cron expressions and computing the next
  scheduled run time from a given reference point.
  Used in background job schedulers, ETL pipelines, and
  recurring-event systems.
  """

  @type cron_field :: :minute | :hour | :day_of_month | :month | :day_of_week
  @type parsed_cron :: %{
          minute: [non_neg_integer()],
          hour: [non_neg_integer()],
          day_of_month: [non_neg_integer()],
          month: [non_neg_integer()],
          day_of_week: [non_neg_integer()]
        }

  @field_ranges %{
    minute: 0..59,
    hour: 0..23,
    day_of_month: 1..31,
    month: 1..12,
    day_of_week: 0..6
  }

  @doc """
  Parses a standard five-field cron expression string into a map
  of expanded integer lists for each field.
  """
  @spec parse(String.t()) :: {:ok, parsed_cron()} | {:error, String.t()}
  def parse(expression) when is_binary(expression) do
    parts = String.split(expression, " ", trim: true)

    if length(parts) != 5 do
      {:error, "Cron expression must have exactly 5 fields, got: #{length(parts)}"}
    else
      [min_str, hr_str, dom_str, mon_str, dow_str] = parts
      fields = [:minute, :hour, :day_of_month, :month, :day_of_week]
      raw = [min_str, hr_str, dom_str, mon_str, dow_str]

      results =
        Enum.zip(fields, raw)
        |> Enum.map(fn {field, value} -> {field, parse_field(value, @field_ranges[field])} end)

      errors = Enum.filter(results, fn {_, v} -> match?({:error, _}, v) end)

      if errors == [] do
        parsed =
          Map.new(results, fn {field, {:ok, values}} -> {field, values} end)

        {:ok, parsed}
      else
        {:error, "Invalid cron fields: #{inspect(errors)}"}
      end
    end
  end

  @doc """
  Computes the next DateTime at which the given cron expression
  would fire, starting from `from` (defaults to now).
  The timezone used for alignment is read from application config.
  """
  @spec next_run(parsed_cron(), DateTime.t() | nil) :: DateTime.t()
  def next_run(parsed, from \\ nil) do
    timezone = Application.fetch_env!(:cron_parser, :default_timezone)

    base =
      case from do
        nil -> DateTime.now!(timezone)
        dt -> DateTime.shift_zone!(dt, timezone)
      end

    start = DateTime.add(base, 60, :second)
    find_next(parsed, start, 0)
  end

  @doc "Returns true if the expression is syntactically valid."
  @spec valid_expression?(String.t()) :: boolean()
  def valid_expression?(expr), do: match?({:ok, _}, parse(expr))

  @doc "Describes a parsed cron map in human-readable form."
  @spec describe(parsed_cron()) :: String.t()
  def describe(%{minute: mins, hour: hours}) do
    min_str = if mins == Enum.to_list(0..59), do: "every minute", else: "minute(s) #{inspect(mins)}"
    hr_str = if hours == Enum.to_list(0..23), do: "every hour", else: "hour(s) #{inspect(hours)}"
    "Runs at #{min_str} past #{hr_str}"
  end

  # --- Private helpers ---

  defp parse_field("*", range), do: {:ok, Enum.to_list(range)}

  defp parse_field(expr, range) when is_struct(range, Range) do
    cond do
      String.contains?(expr, "/") ->
        [base, step_str] = String.split(expr, "/", parts: 2)
        with {step, ""} <- Integer.parse(step_str),
             {:ok, base_vals} <- parse_field(base, range) do
          {:ok, base_vals |> Enum.filter(fn v -> rem(v - Enum.min(base_vals), step) == 0 end)}
        else
          _ -> {:error, "Invalid step: #{expr}"}
        end

      String.contains?(expr, "-") ->
        [lo_str, hi_str] = String.split(expr, "-", parts: 2)
        with {lo, ""} <- Integer.parse(lo_str),
             {hi, ""} <- Integer.parse(hi_str),
             true <- lo in range and hi in range and lo <= hi do
          {:ok, Enum.to_list(lo..hi)}
        else
          _ -> {:error, "Invalid range: #{expr}"}
        end

      String.contains?(expr, ",") ->
        vals =
          expr
          |> String.split(",")
          |> Enum.map(&Integer.parse/1)

        if Enum.all?(vals, &match?({_, ""}, &1)) do
          {:ok, Enum.map(vals, fn {v, _} -> v end) |> Enum.filter(&(&1 in range))}
        else
          {:error, "Invalid list: #{expr}"}
        end

      true ->
        case Integer.parse(expr) do
          {v, ""} when v in range -> {:ok, [v]}
          _ -> {:error, "Out of range: #{expr}"}
        end
    end
  end

  defp find_next(_parsed, _dt, attempts) when attempts > 366 * 24 * 60 do
    raise "Could not find next cron run within one year"
  end

  defp find_next(parsed, dt, attempts) do
    if matches?(parsed, dt), do: dt, else: find_next(parsed, DateTime.add(dt, 60, :second), attempts + 1)
  end

  defp matches?(parsed, dt) do
    parsed.minute |> Enum.member?(dt.minute) and
      parsed.hour |> Enum.member?(dt.hour) and
      parsed.day_of_month |> Enum.member?(dt.day) and
      parsed.month |> Enum.member?(dt.month) and
      parsed.day_of_week |> Enum.member?(Date.day_of_week(DateTime.to_date(dt)) |> rem(7))
  end
end
```
