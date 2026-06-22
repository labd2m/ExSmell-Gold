```elixir
defmodule Reporting.Aggregation do
  @moduledoc """
  Pure data aggregation functions for computing time-series metrics
  from a flat list of event maps. All functions are stateless and
  operate on in-memory data, making them straightforward to test.
  """

  @type event :: %{timestamp: DateTime.t(), value: number(), labels: map()}
  @type bucket_key :: {integer(), integer()}

  @spec sum_by_label(list(event()), atom()) :: %{term() => number()}
  def sum_by_label(events, label_key) when is_list(events) and is_atom(label_key) do
    Enum.reduce(events, %{}, fn event, acc ->
      label_value = get_in(event, [:labels, label_key])
      Map.update(acc, label_value, event.value, &(&1 + event.value))
    end)
  end

  @spec count_by_label(list(event()), atom()) :: %{term() => non_neg_integer()}
  def count_by_label(events, label_key) when is_list(events) and is_atom(label_key) do
    Enum.reduce(events, %{}, fn event, acc ->
      label_value = get_in(event, [:labels, label_key])
      Map.update(acc, label_value, 1, &(&1 + 1))
    end)
  end

  @spec bucket_by_hour(list(event())) :: %{bucket_key() => list(event())}
  def bucket_by_hour(events) when is_list(events) do
    Enum.group_by(events, fn %{timestamp: ts} ->
      {ts.year * 10_000 + ts.month * 100 + ts.day, ts.hour}
    end)
  end

  @spec bucket_by_day(list(event())) :: %{Date.t() => list(event())}
  def bucket_by_day(events) when is_list(events) do
    Enum.group_by(events, fn %{timestamp: ts} -> DateTime.to_date(ts) end)
  end

  @spec moving_average(list(number()), pos_integer()) :: list(float())
  def moving_average(values, window) when is_list(values) and is_integer(window) and window > 0 do
    values
    |> Enum.chunk_every(window, 1, :discard)
    |> Enum.map(fn chunk -> Enum.sum(chunk) / length(chunk) end)
  end

  @spec percentile(list(number()), float()) :: number() | nil
  def percentile([], _pct), do: nil

  def percentile(values, pct) when is_list(values) and is_float(pct) and pct >= 0.0 and pct <= 1.0 do
    sorted = Enum.sort(values)
    index = round(pct * (length(sorted) - 1))
    Enum.at(sorted, index)
  end

  @spec describe(list(number())) :: %{count: non_neg_integer(), min: number() | nil,
                                       max: number() | nil, mean: float() | nil,
                                       p50: number() | nil, p95: number() | nil, p99: number() | nil}
  def describe([]) do
    %{count: 0, min: nil, max: nil, mean: nil, p50: nil, p95: nil, p99: nil}
  end

  def describe(values) when is_list(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      count: count,
      min: List.first(sorted),
      max: List.last(sorted),
      mean: Float.round(Enum.sum(sorted) / count, 4),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99)
    }
  end
end

defmodule Reporting.TimeSeriesBuilder do
  @moduledoc """
  Constructs time-series charts from pre-aggregated daily buckets.
  Gaps in sparse data are filled with a configurable fill value
  to produce a continuous date range suitable for rendering.
  """

  alias Reporting.Aggregation

  @type data_point :: %{date: Date.t(), value: number()}

  @spec build(list(Aggregation.event()), Date.t(), Date.t(), keyword()) :: list(data_point())
  def build(events, from_date, to_date, opts \\ [])
      when is_list(events) and is_struct(from_date, Date) and is_struct(to_date, Date) do
    fill_value = Keyword.get(opts, :fill_value, 0)
    aggregate_fn = Keyword.get(opts, :aggregate, &Enum.sum/1)

    bucketed = Aggregation.bucket_by_day(events)

    date_range = Date.range(from_date, to_date)

    Enum.map(date_range, fn date ->
      value =
        case Map.get(bucketed, date) do
          nil -> fill_value
          bucket_events -> bucket_events |> Enum.map(& &1.value) |> aggregate_fn.()
        end

      %{date: date, value: value}
    end)
  end

  @spec cumulative(list(data_point())) :: list(data_point())
  def cumulative(series) when is_list(series) do
    {result, _} =
      Enum.map_reduce(series, 0, fn %{date: date, value: v}, acc ->
        running = acc + v
        {%{date: date, value: running}, running}
      end)

    result
  end
end
```
