```elixir
defmodule Reporting.PeriodAggregator do
  @moduledoc """
  Aggregates numerical time-series events into period buckets: hourly, daily,
  weekly, and monthly. Each event carries a value and a UTC timestamp.
  Aggregations compute sum, mean, min, max, and count per bucket. All
  computation is pure and operates on in-memory lists with no database
  dependency so the module is fully testable in isolation.
  """

  @type event :: %{value: number(), occurred_at: DateTime.t()}
  @type bucket :: :hourly | :daily | :weekly | :monthly
  @type bucket_key :: String.t()
  @type stats :: %{
          count: non_neg_integer(),
          sum: number(),
          mean: float(),
          min: number(),
          max: number()
        }
  @type aggregate_result :: %{bucket_key() => stats()}

  @doc "Groups `events` into `bucket`-sized time windows and returns per-window stats."
  @spec aggregate([event()], bucket()) :: aggregate_result()
  def aggregate(events, bucket)
      when is_list(events) and bucket in [:hourly, :daily, :weekly, :monthly] do
    events
    |> Enum.group_by(fn e -> bucket_key(e.occurred_at, bucket) end)
    |> Map.new(fn {key, group} -> {key, compute_stats(group)} end)
  end

  @doc "Returns the bucket key string for a given datetime and bucket size."
  @spec bucket_key(DateTime.t(), bucket()) :: bucket_key()
  def bucket_key(%DateTime{} = dt, :hourly) do
    "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}T#{pad(dt.hour)}"
  end

  def bucket_key(%DateTime{} = dt, :daily) do
    "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  end

  def bucket_key(%DateTime{} = dt, :weekly) do
    date = DateTime.to_date(dt)
    iso_week = Date.day_of_week(date)
    monday = Date.add(date, -(iso_week - 1))
    "#{monday.year}-W#{monday |> Date.day_of_week() |> Integer.to_string() |> String.pad_leading(2, "0")}-#{monday}"
  end

  def bucket_key(%DateTime{} = dt, :monthly) do
    "#{dt.year}-#{pad(dt.month)}"
  end

  @doc "Merges two aggregate result maps, summing overlapping bucket statistics."
  @spec merge(aggregate_result(), aggregate_result()) :: aggregate_result()
  def merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, s1, s2 -> merge_stats(s1, s2) end)
  end

  defp compute_stats([]), do: %{count: 0, sum: 0, mean: 0.0, min: nil, max: nil}

  defp compute_stats(events) do
    values = Enum.map(events, & &1.value)
    count = length(values)
    sum = Enum.sum(values)

    %{
      count: count,
      sum: sum,
      mean: sum / count,
      min: Enum.min(values),
      max: Enum.max(values)
    }
  end

  defp merge_stats(s1, s2) do
    count = s1.count + s2.count
    sum = s1.sum + s2.sum

    %{
      count: count,
      sum: sum,
      mean: if(count > 0, do: sum / count, else: 0.0),
      min: Enum.min([s1.min, s2.min] |> Enum.reject(&is_nil/1)),
      max: Enum.max([s1.max, s2.max] |> Enum.reject(&is_nil/1))
    }
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
```
