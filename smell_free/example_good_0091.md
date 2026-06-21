# File: `example_good_91.md`

```elixir
defmodule Stats.Histogram do
  @moduledoc """
  Immutable histogram data structure for tracking the distribution of
  numeric observations across configurable fixed-width buckets.

  All operations are pure; a histogram is created once with its bucket
  configuration and values are added by returning a new updated struct.
  """

  @enforce_keys [:bucket_size, :buckets]
  defstruct [:bucket_size, :buckets, count: 0, sum: 0, min: nil, max: nil]

  @type t :: %__MODULE__{
          bucket_size: number(),
          buckets: %{integer() => non_neg_integer()},
          count: non_neg_integer(),
          sum: number(),
          min: number() | nil,
          max: number() | nil
        }

  @doc """
  Creates a new empty histogram with the given bucket width.

  All observations are placed into buckets of size `bucket_size` aligned
  to zero. For example, with `bucket_size: 10`, a value of `23` falls
  into bucket `20`.
  """
  @spec new(number()) :: t()
  def new(bucket_size) when is_number(bucket_size) and bucket_size > 0 do
    %__MODULE__{bucket_size: bucket_size, buckets: %{}}
  end

  @doc """
  Records a single observation into the histogram.

  Returns a new histogram with the updated bucket counts and summary stats.
  """
  @spec record(t(), number()) :: t()
  def record(%__MODULE__{} = hist, value) when is_number(value) do
    bucket_key = bucket_for(hist.bucket_size, value)

    %__MODULE__{
      hist
      | buckets: Map.update(hist.buckets, bucket_key, 1, &(&1 + 1)),
        count: hist.count + 1,
        sum: hist.sum + value,
        min: update_min(hist.min, value),
        max: update_max(hist.max, value)
    }
  end

  @doc """
  Records all values in a list into the histogram.

  Returns a new histogram with all observations applied.
  """
  @spec record_many(t(), [number()]) :: t()
  def record_many(%__MODULE__{} = hist, values) when is_list(values) do
    Enum.reduce(values, hist, &record(&2, &1))
  end

  @doc """
  Returns the arithmetic mean of all recorded observations.

  Returns `nil` when no observations have been recorded.
  """
  @spec mean(t()) :: float() | nil
  def mean(%__MODULE__{count: 0}), do: nil
  def mean(%__MODULE__{sum: sum, count: count}), do: sum / count

  @doc """
  Returns the approximate percentile value using linear interpolation
  across bucket boundaries.

  `percentile` must be a float between 0.0 and 100.0.
  Returns `nil` when no observations have been recorded.
  """
  @spec percentile(t(), float()) :: float() | nil
  def percentile(%__MODULE__{count: 0}, _pct), do: nil

  def percentile(%__MODULE__{} = hist, pct) when is_float(pct) and pct >= 0.0 and pct <= 100.0 do
    target_rank = ceil(hist.count * pct / 100.0)

    hist.buckets
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> find_percentile_bucket(target_rank, 0, hist.bucket_size)
  end

  @doc """
  Returns a sorted list of `{bucket_lower_bound, count}` tuples for
  all non-empty buckets.
  """
  @spec to_series(t()) :: [{number(), non_neg_integer()}]
  def to_series(%__MODULE__{buckets: buckets}) do
    buckets
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Enum.map(fn {key, count} -> {key, count} end)
  end

  @doc """
  Merges two histograms that share the same bucket size into one.

  Returns `{:error, :incompatible_bucket_sizes}` when bucket sizes differ.
  """
  @spec merge(t(), t()) :: {:ok, t()} | {:error, :incompatible_bucket_sizes}
  def merge(%__MODULE__{bucket_size: s} = a, %__MODULE__{bucket_size: s} = b) do
    merged_buckets =
      Map.merge(a.buckets, b.buckets, fn _key, ca, cb -> ca + cb end)

    merged = %__MODULE__{
      bucket_size: s,
      buckets: merged_buckets,
      count: a.count + b.count,
      sum: a.sum + b.sum,
      min: merge_min(a.min, b.min),
      max: merge_max(a.max, b.max)
    }

    {:ok, merged}
  end

  def merge(%__MODULE__{}, %__MODULE__{}), do: {:error, :incompatible_bucket_sizes}

  defp bucket_for(bucket_size, value) do
    floor(value / bucket_size) * bucket_size
  end

  defp update_min(nil, value), do: value
  defp update_min(current, value), do: min(current, value)

  defp update_max(nil, value), do: value
  defp update_max(current, value), do: max(current, value)

  defp merge_min(nil, b), do: b
  defp merge_min(a, nil), do: a
  defp merge_min(a, b), do: min(a, b)

  defp merge_max(nil, b), do: b
  defp merge_max(a, nil), do: a
  defp merge_max(a, b), do: max(a, b)

  defp find_percentile_bucket([], _target, _cumulative, _size), do: nil

  defp find_percentile_bucket([{key, count} | rest], target, cumulative, size) do
    new_cumulative = cumulative + count

    if new_cumulative >= target do
      key + size * (target - cumulative) / count
    else
      find_percentile_bucket(rest, target, new_cumulative, size)
    end
  end
end
```
