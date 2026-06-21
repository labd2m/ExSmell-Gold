# File: `example_good_551.md`

```elixir
defmodule Reporting.TimeSeriesAggregator do
  @moduledoc """
  Aggregates a stream of timestamped numeric measurements into a
  uniform time-bucket grid with configurable bucket width and
  aggregation function.

  The aggregator fills empty buckets with a configurable fill value
  (nil or zero) so callers receive a dense, gapless series suitable
  for charting without additional client-side interpolation.
  """

  @type timestamp :: DateTime.t()
  @type value :: number()
  @type measurement :: {timestamp(), value()}
  @type bucket_key :: DateTime.t()
  @type aggregation :: :sum | :mean | :min | :max | :count | :last

  @type bucket_result :: %{
          bucket_start: bucket_key(),
          value: value() | nil
        }

  @type aggregate_opts :: [
          aggregation: aggregation(),
          fill_empty: :nil | :zero | :previous
        ]

  @doc """
  Aggregates `measurements` into time buckets of `bucket_seconds` width.

  The grid spans from the earliest to the latest timestamp in the data.
  Buckets are aligned to UTC epoch multiples of `bucket_seconds`.

  Options:
  - `:aggregation` — function applied within each bucket (default: `:sum`)
  - `:fill_empty` — how to fill buckets with no data: `:nil` (default),
    `:zero`, or `:previous` (carry-forward last known value)

  Returns a list of `bucket_result` maps sorted by `bucket_start`.
  """
  @spec aggregate([measurement()], pos_integer(), aggregate_opts()) :: [bucket_result()]
  def aggregate(measurements, bucket_seconds, opts \\ [])
      when is_list(measurements) and is_integer(bucket_seconds) and bucket_seconds > 0 do
    aggregation = Keyword.get(opts, :aggregation, :sum)
    fill_empty = Keyword.get(opts, :fill_empty, :nil)

    if measurements == [] do
      []
    else
      grouped = group_into_buckets(measurements, bucket_seconds)
      grid = build_grid(grouped, bucket_seconds)
      filled = fill_gaps(grid, fill_empty)
      Enum.map(filled, fn {bucket_start, values} ->
        %{bucket_start: bucket_start, value: apply_aggregation(values, aggregation)}
      end)
    end
  end

  @doc """
  Computes a rolling aggregate over a list of bucket results using a
  window of `window_size` buckets.

  Returns a new list of bucket results where each value is the aggregate
  of the preceding `window_size` buckets (inclusive).
  """
  @spec rolling([bucket_result()], pos_integer(), aggregation()) :: [bucket_result()]
  def rolling(buckets, window_size, aggregation \\ :mean)
      when is_list(buckets) and is_integer(window_size) and window_size > 0 do
    buckets
    |> Enum.with_index()
    |> Enum.map(fn {bucket, idx} ->
      window_start = max(idx - window_size + 1, 0)
      window_values =
        buckets
        |> Enum.slice(window_start, idx - window_start + 1)
        |> Enum.map(& &1.value)
        |> Enum.reject(&is_nil/1)

      %{bucket | value: apply_aggregation(window_values, aggregation)}
    end)
  end

  defp group_into_buckets(measurements, bucket_seconds) do
    Enum.group_by(measurements, fn {ts, _v} ->
      unix = DateTime.to_unix(ts)
      aligned = div(unix, bucket_seconds) * bucket_seconds
      DateTime.from_unix!(aligned)
    end, fn {_ts, v} -> v end)
  end

  defp build_grid(grouped, bucket_seconds) do
    bucket_keys = Map.keys(grouped)
    min_ts = Enum.min_by(bucket_keys, &DateTime.to_unix/1)
    max_ts = Enum.max_by(bucket_keys, &DateTime.to_unix/1)

    min_unix = DateTime.to_unix(min_ts)
    max_unix = DateTime.to_unix(max_ts)

    min_unix
    |> Stream.iterate(&(&1 + bucket_seconds))
    |> Stream.take_while(&(&1 <= max_unix))
    |> Enum.map(fn unix ->
      key = DateTime.from_unix!(unix)
      {key, Map.get(grouped, key, [])}
    end)
  end

  defp fill_gaps(grid, :nil) do
    Enum.map(grid, fn {key, values} -> {key, if(values == [], do: nil, else: values)} end)
  end

  defp fill_gaps(grid, :zero) do
    Enum.map(grid, fn {key, values} -> {key, if(values == [], do: [0], else: values)} end)
  end

  defp fill_gaps(grid, :previous) do
    {filled, _last} =
      Enum.map_reduce(grid, nil, fn {key, values}, last_val ->
        if values == [] do
          {{key, if(is_nil(last_val), do: nil, else: [last_val])}, last_val}
        else
          agg = apply_aggregation(values, :last)
          {{key, values}, agg}
        end
      end)

    filled
  end

  defp apply_aggregation(nil, _), do: nil
  defp apply_aggregation([], _), do: nil
  defp apply_aggregation(values, :sum), do: Enum.sum(values)
  defp apply_aggregation(values, :count), do: length(values)
  defp apply_aggregation(values, :mean), do: Enum.sum(values) / length(values)
  defp apply_aggregation(values, :min), do: Enum.min(values)
  defp apply_aggregation(values, :max), do: Enum.max(values)
  defp apply_aggregation(values, :last), do: List.last(values)
end
```
