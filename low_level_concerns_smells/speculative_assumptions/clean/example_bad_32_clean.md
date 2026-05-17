```elixir
defmodule Scheduling.RecurrenceParser do
  @moduledoc """
  Parses iCalendar RRULE strings into structured recurrence descriptors
  used by the scheduling engine to compute future event occurrences.

  Supported RRULE format:
    FREQ=<freq>;INTERVAL=<n>;BYDAY=<days>;COUNT=<n>;UNTIL=<date>

  Example:
    FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;COUNT=10
  """

  require Logger

  @frequencies ~w(DAILY WEEKLY MONTHLY YEARLY)
  @weekdays    ~w(MO TU WE TH FR SA SU)

  def parse_rule(rrule) when is_binary(rrule) do
    components =
      rrule
      |> String.upcase()
      |> String.split(";")
      |> Enum.map(fn component ->
        parts = String.split(component, "=")
        key   = List.first(parts)
        value = List.last(parts)
        {key, value}
      end)
      |> Map.new()

    freq     = Map.get(components, "FREQ")
    interval = components |> Map.get("INTERVAL", "1") |> parse_integer()
    byday    = components |> Map.get("BYDAY") |> parse_days()
    count    = components |> Map.get("COUNT") |> parse_integer()
    until    = components |> Map.get("UNTIL") |> parse_date()

    %{
      frequency: freq,
      interval:  interval,
      days:      byday,
      count:     count,
      until:     until
    }
  end

  def parse_rule(_), do: {:error, :invalid_rrule}

  def valid_rule?(%{frequency: freq}) when freq in @frequencies, do: true
  def valid_rule?(_), do: false

  def next_occurrences(%{frequency: "DAILY", interval: interval} = _rule, from, n)
      when is_integer(interval) and interval > 0 do
    Enum.map(0..(n - 1), fn i ->
      Date.add(from, i * interval)
    end)
  end

  def next_occurrences(%{frequency: "WEEKLY", interval: interval, days: days} = _rule, from, n)
      when is_integer(interval) do
    effective_days = if days == [], do: [@weekdays |> Enum.at(Date.day_of_week(from) - 1)], else: days

    Stream.iterate(from, &Date.add(&1, 1))
    |> Stream.filter(fn date ->
      day_abbr = weekday_abbr(date)
      day_abbr in effective_days
    end)
    |> Enum.take(n)
  end

  def next_occurrences(%{frequency: "MONTHLY", interval: interval} = _rule, from, n)
      when is_integer(interval) do
    Enum.map(0..(n - 1), fn i ->
      months_ahead = i * interval
      year         = from.year + div(from.month - 1 + months_ahead, 12)
      month        = rem(from.month - 1 + months_ahead, 12) + 1
      day          = min(from.day, Date.days_in_month(%Date{year: year, month: month, day: 1}))
      Date.new!(year, month, day)
    end)
  end

  def next_occurrences(_, _, _), do: []

  defp parse_integer(nil), do: nil
  defp parse_integer(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_days(nil), do: []
  defp parse_days(str) do
    str
    |> String.split(",")
    |> Enum.filter(&(&1 in @weekdays))
  end

  defp parse_date(nil), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _           -> nil
    end
  end

  defp weekday_abbr(date) do
    Enum.at(@weekdays, Date.day_of_week(date) - 1)
  end
end
```
