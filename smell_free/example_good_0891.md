```elixir
defmodule Metrics.Histogram do
  @moduledoc """
  An in-process histogram for recording and summarising the distribution
  of numeric observations such as request latencies or payload sizes.
  Observations are bucketed into configurable upper-bound boundaries;
  each bucket records the count of observations less than or equal to
  its bound, enabling percentile approximation without storing raw data.
  Suitable for feeding custom Prometheus-style metrics via Telemetry.
  """

  @type boundary :: number()
  @type t :: %__MODULE__{
          buckets: [{boundary(), non_neg_integer()}],
          inf: non_neg_integer(),
          sum: number(),
          count: non_neg_integer()
        }

  @enforce_keys [:buckets, :inf, :sum, :count]
  defstruct [:buckets, :inf, :sum, :count]

  @default_boundaries [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

  @doc """
  Creates a new histogram with `boundaries` as upper-bound bucket limits.
  Boundaries are automatically sorted. Every histogram also has an `+Inf`
  bucket that counts all observations.
  """
  @spec new([boundary()]) :: t()
  def new(boundaries \\ @default_boundaries) when is_list(boundaries) do
    sorted = Enum.sort(boundaries)
    buckets = Enum.map(sorted, fn b -> {b, 0} end)
    %__MODULE__{buckets: buckets, inf: 0, sum: 0, count: 0}
  end

  @doc """
  Records `value` into `histogram`. Increments all buckets with an upper
  bound greater than or equal to `value`, the `+Inf` bucket, and updates
  the running sum and count.
  """
  @spec observe(t(), number()) :: t()
  def observe(%__MODULE__{} = histogram, value) when is_number(value) do
    updated_buckets =
      Enum.map(histogram.buckets, fn {bound, count} ->
        if value <= bound, do: {bound, count + 1}, else: {bound, count}
      end)

    %__MODULE__{
      histogram
      | buckets: updated_buckets,
        inf: histogram.inf + 1,
        sum: histogram.sum + value,
        count: histogram.count + 1
    }
  end

  @doc """
  Returns the arithmetic mean of all observations, or `nil` when empty.
  """
  @spec mean(t()) :: float() | nil
  def mean(%__MODULE__{count: 0}), do: nil
  def mean(%__MODULE__{sum: sum, count: count}), do: sum / count

  @doc """
  Estimates the value at `percentile` (0.0–1.0) using linear interpolation
  between bucket boundaries. Returns `nil` when the histogram is empty.
  """
  @spec percentile(t(), float()) :: float() | nil
  def percentile(%__MODULE__{count: 0}, _p), do: nil

  def percentile(%__MODULE__{} = histogram, p) when p >= 0.0 and p <= 1.0 do
    target_count = p * histogram.count

    result =
      Enum.find_value(histogram.buckets, fn {bound, bucket_count} ->
        if bucket_count >= target_count, do: bound
      end)

    result || :infinity
  end

  @doc """
  Merges two histograms with identical bucket boundaries by summing per-bucket
  counts. Useful for aggregating across multiple processes or nodes.
  """
  @spec merge(t(), t()) :: {:ok, t()} | {:error, :incompatible_boundaries}
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    a_bounds = Enum.map(a.buckets, &elem(&1, 0))
    b_bounds = Enum.map(b.buckets, &elem(&1, 0))

    if a_bounds == b_bounds do
      merged_buckets =
        Enum.zip(a.buckets, b.buckets)
        |> Enum.map(fn {{bound, ca}, {_b, cb}} -> {bound, ca + cb} end)

      merged = %__MODULE__{
        buckets: merged_buckets,
        inf: a.inf + b.inf,
        sum: a.sum + b.sum,
        count: a.count + b.count
      }

      {:ok, merged}
    else
      {:error, :incompatible_boundaries}
    end
  end

  @doc """
  Returns the histogram in Prometheus text exposition format.
  `name` is used as the metric name prefix.
  """
  @spec to_prometheus(t(), binary(), map()) :: binary()
  def to_prometheus(%__MODULE__{} = histogram, name, labels \\ %{}) when is_binary(name) do
    label_str = format_labels(labels)
    lines = Enum.map(histogram.buckets, fn {bound, count} ->
      "#{name}_bucket{#{label_str}le=\"#{bound}\"} #{count}"
    end)

    inf_line = "#{name}_bucket{#{label_str}le=\"+Inf\"} #{histogram.inf}"
    sum_line = "#{name}_sum{#{label_str}} #{histogram.sum}"
    count_line = "#{name}_count{#{label_str}} #{histogram.count}"

    Enum.join(lines ++ [inf_line, sum_line, count_line], "\n")
  end

  defp format_labels(labels) when map_size(labels) == 0, do: ""

  defp format_labels(labels) do
    labels
    |> Enum.map(fn {k, v} -> "#{k}=\"#{v}\"," end)
    |> Enum.join()
  end
end
```
