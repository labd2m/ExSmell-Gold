```elixir
defmodule Scheduling.CronParser do
  @moduledoc """
  Parses and evaluates standard five-field cron expressions
  (minute hour day-of-month month day-of-week). Returns the next
  scheduled `DateTime` after a given reference time. Supports
  wildcards, lists, ranges, and step values per field.
  """

  @type cron_expr :: String.t()
  @type field_spec :: {:wildcard | :list | :range | :step, term()}
  @type parsed :: %{
          minute: field_spec(),
          hour: field_spec(),
          dom: field_spec(),
          month: field_spec(),
          dow: field_spec()
        }

  @field_ranges %{minute: 0..59, hour: 0..23, dom: 1..31, month: 1..12, dow: 0..6}

  @doc "Parses a cron expression string. Returns a structured spec or a parse error."
  @spec parse(cron_expr()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(expr) when is_binary(expr) do
    fields = String.split(String.trim(expr), ~r/\s+/)

    if length(fields) != 5 do
      {:error, "expected 5 fields, got #{length(fields)}"}
    else
      [min, hr, dom, mon, dow] = fields
      field_keys = [:minute, :hour, :dom, :month, :dow]

      fields
      |> Enum.zip(field_keys)
      |> Enum.reduce_while({:ok, %{}}, fn {raw, key}, {:ok, acc} ->
        case parse_field(raw, @field_ranges[key]) do
          {:ok, spec} -> {:cont, {:ok, Map.put(acc, key, spec)}}
          {:error, msg} -> {:halt, {:error, "field #{key}: #{msg}"}}
        end
      end)
    end
  end

  @doc "Returns the next `DateTime` matching `parsed` after `after_dt`."
  @spec next_after(parsed(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :no_match_within_limit}
  def next_after(%{} = parsed, %DateTime{} = after_dt) do
    start = DateTime.add(after_dt, 60, :second)
    find_next(parsed, start, 0)
  end

  defp find_next(_parsed, _dt, attempts) when attempts > 527_040, do: {:error, :no_match_within_limit}

  defp find_next(parsed, dt, attempts) do
    if matches?(parsed, dt), do: {:ok, dt}, else: find_next(parsed, DateTime.add(dt, 60, :second), attempts + 1)
  end

  defp matches?(parsed, dt) do
    field_matches?(parsed.minute, dt.minute) and
      field_matches?(parsed.hour, dt.hour) and
      field_matches?(parsed.month, dt.month) and
      field_matches?(parsed.dom, dt.day) and
      field_matches?(parsed.dow, day_of_week(dt))
  end

  defp field_matches?({:wildcard, _}, _value), do: true
  defp field_matches?({:list, values}, value), do: value in values
  defp field_matches?({:range, first..last}, value), do: value >= first and value <= last
  defp field_matches?({:step, {first..last, step}}, value) do
    value >= first and value <= last and rem(value - first, step) == 0
  end

  defp parse_field("*", _range), do: {:ok, {:wildcard, nil}}

  defp parse_field(raw, range) do
    cond do
      String.contains?(raw, "/") -> parse_step(raw, range)
      String.contains?(raw, ",") -> parse_list(raw, range)
      String.contains?(raw, "-") -> parse_range(raw, range)
      true -> parse_single(raw, range)
    end
  end

  defp parse_single(raw, range) do
    case Integer.parse(raw) do
      {n, ""} when n in range -> {:ok, {:list, [n]}}
      _ -> {:error, "invalid value '#{raw}'"}
    end
  end

  defp parse_list(raw, range) do
    results = Enum.map(String.split(raw, ","), &parse_single(&1, range))
    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:error, "invalid list '#{raw}'"}
    else
      {:ok, {:list, Enum.flat_map(results, fn {:ok, {:list, vs}} -> vs end)}}
    end
  end

  defp parse_range(raw, _range) do
    case String.split(raw, "-") do
      [a, b] ->
        with {fa, ""} <- Integer.parse(a), {fb, ""} <- Integer.parse(b) do
          {:ok, {:range, fa..fb}}
        else
          _ -> {:error, "invalid range '#{raw}'"}
        end
      _ -> {:error, "invalid range '#{raw}'"}
    end
  end

  defp parse_step("*/" <> step_raw, range) do
    case Integer.parse(step_raw) do
      {step, ""} when step > 0 -> {:ok, {:step, {range, step}}}
      _ -> {:error, "invalid step '#{step_raw}'"}
    end
  end

  defp parse_step(_raw, _range), do: {:error, "unsupported step format"}

  defp day_of_week(dt), do: dt |> DateTime.to_date() |> Date.day_of_week() |> rem(7)
end
```
