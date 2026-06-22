```elixir
defmodule Metrics.Aggregator do
  @moduledoc """
  Aggregates time-series metric samples into windowed rollup summaries.

  Supports count, sum, average, minimum, and maximum aggregations over
  arbitrary time windows. All operations are pure; no storage is performed here.
  """

  alias Metrics.Aggregator.{Sample, Window, Rollup}

  @doc """
  Groups samples into windows of the given duration and computes rollups for each.
  """
  @spec rollup([Sample.t()], pos_integer(), keyword()) :: [Rollup.t()]
  def rollup(samples, window_seconds, opts \\ [])
      when is_list(samples) and is_integer(window_seconds) and window_seconds > 0 do
    aggregations = Keyword.get(opts, :aggregations, [:count, :sum, :avg, :min, :max])

    samples
    |> Enum.group_by(&Window.for_sample(&1, window_seconds))
    |> Enum.map(fn {window, group} ->
      compute_rollup(window, group, aggregations)
    end)
    |> Enum.sort_by(& &1.window_start, DateTime)
  end

  @doc """
  Computes a single rollup over a flat list of samples.
  """
  @spec summarise([Sample.t()]) :: {:ok, map()} | {:error, String.t()}
  def summarise([]), do: {:error, "no samples to summarise"}

  def summarise(samples) when is_list(samples) do
    values = Enum.map(samples, & &1.value)
    count = length(values)
    total = Enum.sum(values)

    {:ok, %{
      count: count,
      sum: total,
      avg: total / count,
      min: Enum.min(values),
      max: Enum.max(values)
    }}
  end

  @doc """
  Filters samples to those falling within the given UTC datetime range.
  """
  @spec in_range([Sample.t()], DateTime.t(), DateTime.t()) :: [Sample.t()]
  def in_range(samples, %DateTime{} = from, %DateTime{} = to) when is_list(samples) do
    Enum.filter(samples, fn %Sample{recorded_at: ts} ->
      DateTime.compare(ts, from) != :lt and DateTime.compare(ts, to) != :gt
    end)
  end

  defp compute_rollup(window, samples, aggregations) do
    values = Enum.map(samples, & &1.value)
    count = length(values)
    total = Enum.sum(values)

    stats = %{}
    |> put_if(:count, aggregations, count)
    |> put_if(:sum, aggregations, total)
    |> put_if(:avg, aggregations, if(count > 0, do: total / count, else: 0.0))
    |> put_if(:min, aggregations, if(values != [], do: Enum.min(values), else: nil))
    |> put_if(:max, aggregations, if(values != [], do: Enum.max(values), else: nil))

    Rollup.new(window, count, stats)
  end

  defp put_if(map, key, aggregations, value) do
    if key in aggregations, do: Map.put(map, key, value), else: map
  end
end

defmodule Metrics.Aggregator.Sample do
  @moduledoc "A single metric observation at a point in time."

  @enforce_keys [:metric, :value, :recorded_at]
  defstruct [:metric, :value, :recorded_at, tags: %{}]

  @type t :: %__MODULE__{
          metric: String.t(),
          value: number(),
          recorded_at: DateTime.t(),
          tags: map()
        }

  @spec new(String.t(), number(), DateTime.t(), map()) :: t()
  def new(metric, value, recorded_at, tags \\ %{})
      when is_binary(metric) and is_number(value) do
    %__MODULE__{metric: metric, value: value, recorded_at: recorded_at, tags: tags}
  end
end

defmodule Metrics.Aggregator.Window do
  @moduledoc false

  @spec for_sample(Metrics.Aggregator.Sample.t(), pos_integer()) :: DateTime.t()
  def for_sample(%{recorded_at: ts}, window_seconds) do
    epoch = DateTime.to_unix(ts)
    bucket_start = div(epoch, window_seconds) * window_seconds
    DateTime.from_unix!(bucket_start)
  end
end

defmodule Metrics.Aggregator.Rollup do
  @moduledoc "A computed statistical summary over a time window."

  @enforce_keys [:window_start, :sample_count, :stats]
  defstruct [:window_start, :sample_count, :stats]

  @type t :: %__MODULE__{
          window_start: DateTime.t(),
          sample_count: non_neg_integer(),
          stats: map()
        }

  @spec new(DateTime.t(), non_neg_integer(), map()) :: t()
  def new(window_start, sample_count, stats) do
    %__MODULE__{window_start: window_start, sample_count: sample_count, stats: stats}
  end
end
```
