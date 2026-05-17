```elixir
defmodule Scheduling.RecurringRuleParser do
  @moduledoc """
  Parses recurrence rule strings used by the scheduling service to define repeating events.

  The platform uses a simplified RRULE-inspired format where each scheduling
  dimension is expressed as a `KEY=VALUE` pair, with pairs separated by `";"`:

    "FREQ=<frequency>;INTERVAL=<n>;BYDAY=<days>;UNTIL=<ISO8601_date>"

  Example rules:
    "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR"
    "FREQ=MONTHLY;INTERVAL=1;BYDAY=1MO"
    "FREQ=DAILY;INTERVAL=2;UNTIL=2024-06-30"
    "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=2024-12-31"

  The parsed result is used to expand occurrences for calendar rendering
  and to generate reminder notifications.
  """

  require Logger

  @supported_frequencies ~w(DAILY WEEKLY MONTHLY YEARLY)
  @supported_days        ~w(MO TU WE TH FR SA SU)

  defstruct [:frequency, :interval, :by_day, :until, :raw]

  @doc """
  Parses a recurrence rule string into a `%RecurringRuleParser{}` struct.

  Returns `{:ok, struct}` on success, or `{:error, reason}` on validation failure.
  """
  def parse(rule_string) when is_binary(rule_string) do
    field_map =
      rule_string
      |> String.split(";")
      |> Enum.reduce(%{}, fn field_str, acc ->
        case parse_field(field_str) do
          {:ok, {key, value}} -> Map.put(acc, key, value)
          {:error, _reason}   -> acc
        end
      end)

    with {:ok, freq}  <- fetch_frequency(field_map),
         {:ok, itvl}  <- fetch_interval(field_map) do
      {:ok, %__MODULE__{
        frequency: freq,
        interval:  itvl,
        by_day:    Map.get(field_map, "BYDAY"),
        until:     parse_until(Map.get(field_map, "UNTIL")),
        raw:       rule_string
      }}
    end
  end

  @doc """
  Splits a single `"KEY=VALUE"` field string into a key-value pair.
  """

  def parse_field(field_str) when is_binary(field_str) do
    parts = String.split(field_str, "=")
    key   = Enum.at(parts, 0)
    value = Enum.at(parts, 1)

    if is_binary(key) and is_binary(value) do
      {:ok, {String.upcase(key), value}}
    else
      {:error, {:malformed_field, field_str}}
    end
  end

  @doc """
  Expands a recurrence rule into the next N occurrence dates from a start date.
  """
  def next_occurrences(%__MODULE__{} = rule, start_date, count \\ 10) do
    start_date
    |> Stream.iterate(&advance_date(&1, rule))
    |> Stream.drop(1)
    |> Stream.filter(&matches_byday?(&1, rule.by_day))
    |> Stream.take_while(&before_until?(&1, rule.until))
    |> Enum.take(count)
  end

  @doc """
  Returns true when the rule has an end date set.
  """
  def bounded?(%__MODULE__{until: nil}), do: false
  def bounded?(_), do: true

  @doc """
  Returns all supported frequency identifiers.
  """
  def supported_frequencies, do: @supported_frequencies

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_frequency(%{"FREQ" => freq}) when freq in @supported_frequencies, do: {:ok, freq}
  defp fetch_frequency(%{"FREQ" => freq}), do: {:error, {:unsupported_frequency, freq}}
  defp fetch_frequency(_), do: {:error, :missing_frequency}

  defp fetch_interval(%{"INTERVAL" => str}) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _                  -> {:error, {:invalid_interval, str}}
    end
  end

  defp fetch_interval(_), do: {:ok, 1}

  defp parse_until(nil), do: nil

  defp parse_until(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _           -> nil
    end
  end

  defp advance_date(date, %__MODULE__{frequency: "DAILY",   interval: n}), do: Date.add(date, n)
  defp advance_date(date, %__MODULE__{frequency: "WEEKLY",  interval: n}), do: Date.add(date, n * 7)
  defp advance_date(date, %__MODULE__{frequency: "MONTHLY", interval: n}), do: Date.add(date, n * 30)
  defp advance_date(date, %__MODULE__{frequency: "YEARLY",  interval: n}), do: Date.add(date, n * 365)
  defp advance_date(date, _), do: Date.add(date, 1)

  defp matches_byday?(_date, nil), do: true

  defp matches_byday?(date, byday) when is_binary(byday) do
    day_names = String.split(byday, ",")
    day_of_week = date |> Date.day_of_week() |> day_index_to_name()
    day_of_week in day_names
  end

  defp day_index_to_name(1), do: "MO"
  defp day_index_to_name(2), do: "TU"
  defp day_index_to_name(3), do: "WE"
  defp day_index_to_name(4), do: "TH"
  defp day_index_to_name(5), do: "FR"
  defp day_index_to_name(6), do: "SA"
  defp day_index_to_name(7), do: "SU"

  defp before_until?(_date, nil), do: true
  defp before_until?(date, until), do: Date.compare(date, until) != :gt
end
```
