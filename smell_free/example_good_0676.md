```elixir
defmodule Stream.Scanner do
  @moduledoc """
  Provides `scan/3`, a stateful stream transformation that passes an
  accumulator through each element and emits the accumulator value at
  every step — analogous to `Enum.scan/3` but lazy and composable with
  other `Stream` operations.

  Also provides higher-level scanners for common time-series patterns:
  running totals, exponential moving averages, and change detection.
  """

  @spec scan(Enumerable.t(), acc, (term(), acc -> acc)) :: Enumerable.t() when acc: term()
  def scan(stream, initial, fun) when is_function(fun, 2) do
    stream
    |> Stream.transform(initial, fn element, acc ->
      new_acc = fun.(element, acc)
      {[new_acc], new_acc}
    end)
  end

  @spec running_sum(Enumerable.t()) :: Enumerable.t()
  def running_sum(stream) do
    scan(stream, 0, fn value, total -> total + value end)
  end

  @spec running_count(Enumerable.t()) :: Enumerable.t()
  def running_count(stream) do
    scan(stream, 0, fn _value, count -> count + 1 end)
  end

  @spec running_min(Enumerable.t()) :: Enumerable.t()
  def running_min(stream) do
    scan(stream, nil, fn
      value, nil -> value
      value, min -> min(value, min)
    end)
  end

  @spec running_max(Enumerable.t()) :: Enumerable.t()
  def running_max(stream) do
    scan(stream, nil, fn
      value, nil -> value
      value, max -> max(value, max)
    end)
  end

  @spec ema(Enumerable.t(), float()) :: Enumerable.t()
  def ema(stream, alpha) when alpha > 0.0 and alpha <= 1.0 do
    scan(stream, nil, fn
      value, nil -> value
      value, prev -> alpha * value + (1.0 - alpha) * prev
    end)
  end

  @spec delta(Enumerable.t()) :: Enumerable.t()
  def delta(stream) do
    stream
    |> Stream.transform(:init, fn
      value, :init -> {[], value}
      value, prev -> {[value - prev], value}
    end)
  end

  @spec rate_of_change(Enumerable.t()) :: Enumerable.t()
  def rate_of_change(stream) do
    stream
    |> Stream.transform(:init, fn
      value, :init -> {[], value}
      value, prev when prev != 0 -> {[(value - prev) / prev * 100.0], value}
      value, _prev -> {[0.0], value}
    end)
  end

  @spec with_index_and_state(Enumerable.t(), acc, (term(), non_neg_integer(), acc -> {term(), acc})) ::
          Enumerable.t() when acc: term()
  def with_index_and_state(stream, initial, fun) when is_function(fun, 3) do
    stream
    |> Stream.transform({0, initial}, fn element, {idx, acc} ->
      {emitted, new_acc} = fun.(element, idx, acc)
      {[emitted], {idx + 1, new_acc}}
    end)
  end

  @spec consecutive_duplicates(Enumerable.t()) :: Enumerable.t()
  def consecutive_duplicates(stream) do
    stream
    |> Stream.transform(:init, fn
      value, :init -> {[{value, 1}], {value, 1}}
      value, {prev, count} when value == prev -> {[], {prev, count + 1}}
      value, {prev, count} -> {[{prev, count}, {value, 1}], {value, 1}}
    end)
  end

  @spec chunk_by_state(Enumerable.t(), acc, (term(), acc -> {[term()], acc})) ::
          Enumerable.t() when acc: term()
  def chunk_by_state(stream, initial_acc, fun) when is_function(fun, 2) do
    Stream.transform(stream, initial_acc, fn element, acc ->
      {emissions, new_acc} = fun.(element, acc)
      {emissions, new_acc}
    end)
  end
end
```
