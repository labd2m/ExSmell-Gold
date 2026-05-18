# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Reporting.DurationFormatter` module, `humanize_seconds/1` macro |
| **Affected function(s)** | `humanize_seconds/1` |
| **Short explanation** | `humanize_seconds/1` converts a runtime integer (seconds) into a human-readable string by performing integer division and remainder operations. All inputs and outputs are runtime values; a regular multi-clause function or a `cond`-based `def` would be simpler and equally capable. |

```elixir
defmodule Reporting.DurationFormatter do
  @moduledoc """
  Formats time durations for display in dashboards, reports, and
  activity feeds. Supports seconds-to-human conversion, countdown
  labels, and elapsed-time summaries.
  """

  @minute 60
  @hour   3_600
  @day    86_400
  @week   604_800

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `humanize_seconds/1` operates
  # entirely on a runtime integer. Integer arithmetic and string
  # interpolation are runtime operations; `defmacro` with `quote/unquote`
  # adds indirection without any compile-time benefit. Any caller must
  # now `require` this module just to call what is logically a formatting
  # helper — a plain `def` would be the correct, idiomatic choice.
  defmacro humanize_seconds(total_seconds) do
    quote do
      secs  = unquote(total_seconds)
      weeks  = div(secs, unquote(@week))
      days   = div(rem(secs, unquote(@week)),  unquote(@day))
      hours  = div(rem(secs, unquote(@day)),   unquote(@hour))
      mins   = div(rem(secs, unquote(@hour)),  unquote(@minute))
      remain = rem(secs, unquote(@minute))

      parts =
        [
          {weeks,  "w"},
          {days,   "d"},
          {hours,  "h"},
          {mins,   "m"},
          {remain, "s"}
        ]
        |> Enum.reject(fn {v, _} -> v == 0 end)
        |> Enum.map(fn {v, unit} -> "#{v}#{unit}" end)

      case parts do
        [] -> "0s"
        _  -> Enum.join(parts, " ")
      end
    end
  end
  # VALIDATION: SMELL END

  def format_range(from_dt, to_dt) do
    require Reporting.DurationFormatter

    diff = DateTime.diff(to_dt, from_dt, :second)
    Reporting.DurationFormatter.humanize_seconds(diff)
  end

  def elapsed_since(datetime) do
    require Reporting.DurationFormatter

    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)
    label = Reporting.DurationFormatter.humanize_seconds(diff)
    "#{label} ago"
  end

  def countdown_to(datetime) do
    require Reporting.DurationFormatter

    diff = DateTime.diff(datetime, DateTime.utc_now(), :second)

    if diff <= 0 do
      "now"
    else
      "in #{Reporting.DurationFormatter.humanize_seconds(diff)}"
    end
  end

  def average_duration(events) do
    require Reporting.DurationFormatter

    total =
      Enum.reduce(events, 0, fn e, acc ->
        acc + DateTime.diff(e.ended_at, e.started_at, :second)
      end)

    avg = if length(events) > 0, do: div(total, length(events)), else: 0
    Reporting.DurationFormatter.humanize_seconds(avg)
  end

  def build_event_row(event) do
    require Reporting.DurationFormatter

    duration_secs = DateTime.diff(event.ended_at, event.started_at, :second)

    %{
      id:        event.id,
      name:      event.name,
      started:   Calendar.strftime(event.started_at, "%Y-%m-%d %H:%M"),
      ended:     Calendar.strftime(event.ended_at,   "%Y-%m-%d %H:%M"),
      duration:  Reporting.DurationFormatter.humanize_seconds(duration_secs),
      status:    event.status
    }
  end

  def longest_event(events) do
    Enum.max_by(events, fn e ->
      DateTime.diff(e.ended_at, e.started_at, :second)
    end, fn -> nil end)
  end
end
```
