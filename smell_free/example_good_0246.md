# File: `example_good_246.md`

```elixir
defmodule DataPipeline.StreamDeduplicator do
  @moduledoc """
  GenServer-backed deduplication layer for high-throughput event streams.

  Uses a two-level strategy: an exact-match ETS store for a configurable
  recent window, and a probabilistic bloom filter for older entries.
  Items older than the exact window are checked against the filter with
  a small, bounded false-positive rate.

  The filter is periodically rotated to prevent unbounded growth while
  keeping memory overhead predictable.
  """

  use GenServer

  @exact_window_ms 60_000
  @rotation_interval_ms 300_000
  @filter_size_bits 1_000_000
  @hash_count 7

  @type item_key :: binary()

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Checks whether `key` has been seen recently and marks it as seen.

  Returns `:new` when the key has not been seen before, or
  `:duplicate` when it has. Always marks the key as seen on `:new`.
  """
  @spec check_and_mark(item_key()) :: :new | :duplicate
  def check_and_mark(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:check_and_mark, key})
  end

  @doc """
  Returns statistics about the current deduplication state.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(:dedup_exact, [:named_table, :public, read_concurrency: true])
    filter = new_filter()
    schedule_rotation()

    {:ok, %{filter: filter, prev_filter: nil, seen: 0, duplicates: 0}}
  end

  @impl GenServer
  def handle_call({:check_and_mark, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @exact_window_ms

    {result, new_state} =
      cond do
        exact_seen?(key, cutoff) ->
          {:duplicate, %{state | duplicates: state.duplicates + 1}}

        filter_seen?(state, key) ->
          {:duplicate, %{state | duplicates: state.duplicates + 1}}

        true ->
          mark_exact(key, now)
          new_filter = add_to_filter(state.filter, key)
          {:new, %{state | filter: new_filter, seen: state.seen + 1}}
      end

    {:reply, result, new_state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{
      total_seen: state.seen,
      total_duplicates: state.duplicates,
      exact_window_ms: @exact_window_ms
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:rotate_filter, state) do
    cutoff = System.monotonic_time(:millisecond) - @exact_window_ms
    :ets.select_delete(:dedup_exact, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    schedule_rotation()
    {:noreply, %{state | prev_filter: state.filter, filter: new_filter()}}
  end

  defp exact_seen?(key, cutoff) do
    case :ets.lookup(:dedup_exact, key) do
      [{^key, ts}] -> ts >= cutoff
      [] -> false
    end
  end

  defp filter_seen?(%{filter: f, prev_filter: prev}, key) do
    bloom_contains?(f, key) or (prev != nil and bloom_contains?(prev, key))
  end

  defp mark_exact(key, timestamp) do
    :ets.insert(:dedup_exact, {key, timestamp})
  end

  defp new_filter do
    :atomics.new(@filter_size_bits, signed: false)
  end

  defp add_to_filter(filter, key) do
    key |> hash_positions() |> Enum.each(&:atomics.put(filter, &1, 1))
    filter
  end

  defp bloom_contains?(filter, key) do
    key |> hash_positions() |> Enum.all?(&(:atomics.get(filter, &1) == 1))
  end

  defp hash_positions(key) do
    for seed <- 0..(@hash_count - 1) do
      hash = :erlang.phash2({key, seed}, @filter_size_bits)
      max(1, hash)
    end
  end

  defp schedule_rotation do
    Process.send_after(self(), :rotate_filter, @rotation_interval_ms)
  end
end
```
