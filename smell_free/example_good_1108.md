```elixir
defmodule Reporting.AggregateBuilder do
  @moduledoc """
  Constructs time-bucketed aggregates from a stream of timestamped events.
  Buckets are aligned to UTC boundaries determined by the chosen granularity.
  Aggregation functions are provided by callers, making the builder domain-agnostic.
  """

  @type granularity :: :minute | :hour | :day
  @type event :: %{required(:occurred_at) => DateTime.t()}
  @type bucket_key :: String.t()
  @type aggregate :: term()
  @type reducer :: (event(), aggregate() -> aggregate())
  @type initial_fn :: (() -> aggregate())

  @doc """
  Partitions events into time buckets and reduces each bucket.
  Returns a map of bucket key to aggregate value, sorted chronologically.
  """
  @spec build([event()], granularity(), initial_fn(), reducer()) :: %{
          bucket_key() => aggregate()
        }
  def build(events, granularity, initial_fn, reducer)
      when is_list(events) and granularity in [:minute, :hour, :day] and
             is_function(initial_fn, 0) and is_function(reducer, 2) do
    events
    |> Enum.group_by(&bucket_key(&1.occurred_at, granularity))
    |> Map.new(fn {key, bucket_events} ->
      aggregate = Enum.reduce(bucket_events, initial_fn.(), reducer)
      {key, aggregate}
    end)
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Map.new()
  end

  @doc "Returns the bucket key string for a datetime at the given granularity."
  @spec bucket_key(DateTime.t(), granularity()) :: bucket_key()
  def bucket_key(%DateTime{} = dt, :minute) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
  end

  def bucket_key(%DateTime{} = dt, :hour) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:00")
  end

  def bucket_key(%DateTime{} = dt, :day) do
    Calendar.strftime(dt, "%Y-%m-%d")
  end
end

defmodule Reporting.EventCountAggregate do
  @moduledoc "Example aggregate that simply counts events in each bucket."

  @doc "Initial value for a count aggregate."
  @spec initial() :: non_neg_integer()
  def initial, do: 0

  @doc "Increments the count for each event."
  @spec reducer(map(), non_neg_integer()) :: non_neg_integer()
  def reducer(_event, count), do: count + 1
end

defmodule Reporting.SumAggregate do
  @moduledoc """
  Aggregate that sums a numeric field extracted from each event.
  The field path is provided as a list of keys for nested map access.
  """

  @type field_path :: [atom() | String.t()]

  @doc "Initial value for a sum aggregate."
  @spec initial() :: number()
  def initial, do: 0

  @doc "Adds the extracted numeric field value from the event to the accumulator."
  @spec reducer(map(), field_path(), number()) :: number()
  def reducer(event, field_path, acc) when is_list(field_path) do
    value = get_in(event, field_path)
    add_numeric(acc, value)
  end

  defp add_numeric(acc, v) when is_number(v), do: acc + v
  defp add_numeric(acc, _), do: acc
end
```
