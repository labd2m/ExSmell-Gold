```elixir
defmodule Stream.Window do
  @moduledoc """
  Partitions an ordered stream of timestamped events into fixed-size
  tumbling or sliding time windows and computes per-window aggregations.

  Tumbling windows are non-overlapping; each event belongs to exactly one
  window. Sliding windows advance by a step smaller than their size so
  consecutive windows share events, producing a smoother signal suitable
  for anomaly detection and moving averages.
  """

  @type event :: %{required(:timestamp) => integer(), required(:value) => number()}
  @type window_result :: %{
          window_start: integer(),
          window_end: integer(),
          events: [event()],
          count: non_neg_integer(),
          sum: number(),
          min: number() | nil,
          max: number() | nil,
          mean: float() | nil
        }

  @spec tumbling([event()], pos_integer()) :: [window_result()]
  def tumbling(events, window_ms)
      when is_list(events) and is_integer(window_ms) and window_ms > 0 do
    sorted = Enum.sort_by(events, & &1.timestamp)

    case sorted do
      [] ->
        []

      [first | _] ->
        start_ms = align(first.timestamp, window_ms)
        build_tumbling_windows(sorted, start_ms, window_ms, [])
    end
  end

  @spec sliding([event()], pos_integer(), pos_integer()) :: [window_result()]
  def sliding(events, window_ms, step_ms)
      when is_list(events) and window_ms > 0 and step_ms > 0 and step_ms <= window_ms do
    sorted = Enum.sort_by(events, & &1.timestamp)

    case sorted do
      [] ->
        []

      [first | _] ->
        last_ts = sorted |> List.last() |> Map.fetch!(:timestamp)
        start_ms = align(first.timestamp, step_ms)

        start_ms
        |> Stream.iterate(&(&1 + step_ms))
        |> Stream.take_while(&(&1 <= last_ts))
        |> Enum.map(fn window_start ->
          window_end = window_start + window_ms
          window_events = Enum.filter(sorted, fn e ->
            e.timestamp >= window_start and e.timestamp < window_end
          end)
          build_result(window_start, window_end, window_events)
        end)
    end
  end

  defp build_tumbling_windows([], _start, _size, acc), do: Enum.reverse(acc)

  defp build_tumbling_windows(events, window_start, window_ms, acc) do
    window_end = window_start + window_ms
    {in_window, after_window} = Enum.split_while(events, &(&1.timestamp < window_end))
    result = build_result(window_start, window_end, in_window)
    build_tumbling_windows(after_window, window_end, window_ms, [result | acc])
  end

  defp build_result(window_start, window_end, events) do
    values = Enum.map(events, & &1.value)
    count = length(values)

    %{
      window_start: window_start,
      window_end: window_end,
      events: events,
      count: count,
      sum: Enum.sum(values),
      min: if(count > 0, do: Enum.min(values), else: nil),
      max: if(count > 0, do: Enum.max(values), else: nil),
      mean: if(count > 0, do: Enum.sum(values) / count, else: nil)
    }
  end

  defp align(timestamp, window_ms) do
    div(timestamp, window_ms) * window_ms
  end
end
```
