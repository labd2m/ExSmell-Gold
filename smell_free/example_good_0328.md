```elixir
defmodule TimeSeries.Granularity do
  @moduledoc false

  @type t :: :minute | :hour | :day

  @spec truncate(DateTime.t(), t()) :: DateTime.t()
  def truncate(%DateTime{} = dt, :minute) do
    %{dt | second: 0, microsecond: {0, 0}}
  end

  def truncate(%DateTime{} = dt, :hour) do
    %{dt | minute: 0, second: 0, microsecond: {0, 0}}
  end

  def truncate(%DateTime{} = dt, :day) do
    dt |> DateTime.to_date() |> Date.to_string() |> then(fn d ->
      {:ok, midnight, _} = DateTime.from_iso8601("#{d}T00:00:00Z")
      midnight
    end)
  end

  @spec bucket_key(DateTime.t(), t()) :: String.t()
  def bucket_key(%DateTime{} = dt, granularity) do
    dt |> truncate(granularity) |> DateTime.to_iso8601()
  end
end

defmodule TimeSeries.Aggregator do
  @moduledoc """
  Buckets a stream of timestamped observations by time granularity and
  computes per-bucket aggregations.

  Data points are grouped into fixed-width time windows (minute, hour, or
  day). Within each window, the aggregator computes count, sum, minimum,
  maximum, and arithmetic mean. Buckets with no data are omitted from the
  result rather than emitting zero-filled rows.
  """

  alias TimeSeries.Granularity

  @type observation :: %{
          required(:timestamp) => DateTime.t(),
          required(:value) => number()
        }

  @type bucket_result :: %{
          bucket: String.t(),
          count: non_neg_integer(),
          sum: number(),
          min: number(),
          max: number(),
          mean: float()
        }

  @spec aggregate(Enumerable.t(), Granularity.t()) :: [bucket_result()]
  def aggregate(observations, granularity) when granularity in [:minute, :hour, :day] do
    observations
    |> Enum.group_by(fn obs -> Granularity.bucket_key(obs.timestamp, granularity) end)
    |> Enum.map(fn {bucket, points} -> compute_bucket(bucket, points) end)
    |> Enum.sort_by(& &1.bucket)
  end

  @spec aggregate_by_field(Enumerable.t(), atom(), Granularity.t()) ::
          %{term() => [bucket_result()]}
  def aggregate_by_field(observations, field, granularity)
      when is_atom(field) and granularity in [:minute, :hour, :day] do
    observations
    |> Enum.group_by(& Map.fetch!(&1, field))
    |> Map.new(fn {group_value, group_obs} ->
      {group_value, aggregate(group_obs, granularity)}
    end)
  end

  @spec window_summary([bucket_result()]) :: %{
          total_count: non_neg_integer(),
          overall_min: number() | nil,
          overall_max: number() | nil,
          overall_mean: float() | nil
        }
  def window_summary([]) do
    %{total_count: 0, overall_min: nil, overall_max: nil, overall_mean: nil}
  end

  def window_summary(buckets) do
    total_count = Enum.sum(Enum.map(buckets, & &1.count))
    total_sum = Enum.sum(Enum.map(buckets, & &1.sum))

    %{
      total_count: total_count,
      overall_min: buckets |> Enum.map(& &1.min) |> Enum.min(),
      overall_max: buckets |> Enum.map(& &1.max) |> Enum.max(),
      overall_mean: if(total_count > 0, do: total_sum / total_count, else: nil)
    }
  end

  defp compute_bucket(bucket, points) do
    values = Enum.map(points, & &1.value)
    count = length(values)
    sum = Enum.sum(values)

    %{
      bucket: bucket,
      count: count,
      sum: sum,
      min: Enum.min(values),
      max: Enum.max(values),
      mean: sum / count
    }
  end
end
```
