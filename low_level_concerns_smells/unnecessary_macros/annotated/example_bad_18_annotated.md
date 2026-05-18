# Annotated Example 18 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro duration_label/1` inside `Logistics.TimeHelpers`
- **Affected function(s):** `duration_label/1`
- **Short explanation:** The macro converts a number of seconds into a human-readable string using division, modulo, and string interpolation — all runtime operations. A regular function captures this just as well without forcing callers to `require` the module.

---

```elixir
defmodule Logistics.TimeHelpers do
  @moduledoc """
  Time formatting and duration utilities for the logistics tracking UI
  and audit reports.
  """

  @seconds_per_minute 60
  @seconds_per_hour 3_600
  @seconds_per_day 86_400

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because duration_label/1 only applies integer
  # arithmetic (div, rem) and string interpolation to a runtime integer. There
  # is no compile-time transformation; a def function is the right abstraction.
  defmacro duration_label(seconds) do
    quote do
      secs = unquote(seconds)
      days = div(secs, unquote(@seconds_per_day))
      hours = div(rem(secs, unquote(@seconds_per_day)), unquote(@seconds_per_hour))
      minutes = div(rem(secs, unquote(@seconds_per_hour)), unquote(@seconds_per_minute))

      cond do
        days > 0 -> "#{days}d #{hours}h #{minutes}m"
        hours > 0 -> "#{hours}h #{minutes}m"
        minutes > 0 -> "#{minutes}m"
        true -> "#{secs}s"
      end
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the elapsed seconds between two datetimes.
  The result is always non-negative.
  """
  @spec elapsed_seconds(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def elapsed_seconds(%DateTime{} = from, %DateTime{} = to) do
    abs(DateTime.diff(to, from, :second))
  end

  @doc """
  Returns whether a shipment leg is overdue based on expected arrival.
  """
  @spec overdue?(DateTime.t(), DateTime.t()) :: boolean()
  def overdue?(%DateTime{} = expected, %DateTime{} = now) do
    DateTime.compare(now, expected) == :gt
  end

  @doc """
  Formats a datetime in a concise display format.
  """
  @spec display_datetime(DateTime.t()) :: String.t()
  def display_datetime(%DateTime{} = dt) do
    "#{dt.year}-#{pad2(dt.month)}-#{pad2(dt.day)} #{pad2(dt.hour)}:#{pad2(dt.minute)}"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end

defmodule Logistics.TrackingService do
  @moduledoc """
  Provides real-time and historical tracking data for shipments,
  including elapsed time summaries and delay reporting.
  """

  require Logistics.TimeHelpers

  alias Logistics.TimeHelpers

  @doc """
  Builds a tracking summary for a shipment, including time in each status.
  """
  @spec build_summary(map()) :: map()
  def build_summary(%{events: events, expected_delivery: expected} = shipment) do
    now = DateTime.utc_now()
    first_event = List.first(events)
    latest_event = List.last(events)

    total_elapsed =
      if first_event,
        do: TimeHelpers.elapsed_seconds(first_event.occurred_at, now),
        else: 0

    in_transit_seconds =
      events
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, _b] -> a.status == :in_transit end)
      |> Enum.reduce(0, fn [a, b], acc ->
        acc + TimeHelpers.elapsed_seconds(a.occurred_at, b.occurred_at)
      end)

    %{
      shipment_id: shipment.id,
      current_status: latest_event && latest_event.status,
      total_elapsed_label: TimeHelpers.duration_label(total_elapsed),
      in_transit_label: TimeHelpers.duration_label(in_transit_seconds),
      overdue: TimeHelpers.overdue?(expected, now),
      expected_delivery: TimeHelpers.display_datetime(expected),
      last_updated: latest_event && TimeHelpers.display_datetime(latest_event.occurred_at)
    }
  end

  @doc """
  Returns all overdue shipments from a list, with delay duration labels.
  """
  @spec overdue_shipments(list(map())) :: list(map())
  def overdue_shipments(shipments) do
    now = DateTime.utc_now()

    shipments
    |> Enum.filter(fn s -> TimeHelpers.overdue?(s.expected_delivery, now) end)
    |> Enum.map(fn s ->
      delay_secs = TimeHelpers.elapsed_seconds(s.expected_delivery, now)

      Map.put(s, :delay_label, TimeHelpers.duration_label(delay_secs))
    end)
    |> Enum.sort_by(&TimeHelpers.elapsed_seconds(&1.expected_delivery, now), :desc)
  end
end
```
