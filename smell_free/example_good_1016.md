```elixir
defmodule Platform.FlushCounter do
  @moduledoc """
  A high-throughput counter that accumulates increments in ETS and flushes
  them to the database in batches on a configurable interval.

  Suitable for view counts, download counters, and usage metrics where
  individual database writes would be too expensive. Counters are durable:
  a flush cycle persists all pending increments before resetting the ETS state.
  """

  use GenServer

  require Logger

  @type counter_key :: {atom(), term()}
  @type flush_fn :: (%{optional(counter_key()) => pos_integer()} -> :ok | {:error, term()})

  @default_flush_ms :timer.seconds(30)
  @default_max_drift 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Increments the counter for `key` by `amount`. Non-blocking."
  @spec increment(counter_key(), pos_integer()) :: :ok
  def increment(key, amount \\ 1) when is_integer(amount) and amount > 0 do
    table = :persistent_term.get({__MODULE__, :table})
    :ets.update_counter(table, key, {2, amount}, {key, 0})
    maybe_trigger_flush(table)
    :ok
  end

  @doc "Returns the current pending count for `key` without flushing."
  @spec peek(counter_key()) :: non_neg_integer()
  def peek(key) do
    table = :persistent_term.get({__MODULE__, :table})
    case :ets.lookup(table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  @doc "Forces an immediate flush of all pending counters."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl GenServer
  def init(opts) do
    flush_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_ms)
    flush_fn = Keyword.fetch!(opts, :flush_fn)
    max_drift = Keyword.get(opts, :max_drift, @default_max_drift)

    table = :ets.new(:flush_counters, [:set, :public, :named_table, write_concurrency: true])
    :persistent_term.put({__MODULE__, :table}, table)

    schedule_flush(flush_ms)

    {:ok, %{flush_fn: flush_fn, flush_ms: flush_ms, max_drift: max_drift, table: table, total_flushed: 0}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl GenServer
  def handle_info(:flush, %{flush_ms: flush_ms} = state) do
    schedule_flush(flush_ms)
    {:noreply, do_flush(state)}
  end

  defp do_flush(%{table: table, flush_fn: flush_fn} = state) do
    entries = :ets.tab2list(table)

    if entries == [] do
      state
    else
      pending = Map.new(entries)
      :ets.delete_all_objects(table)

      case flush_fn.(pending) do
        :ok ->
          total = Enum.sum(Map.values(pending))
          Logger.debug("[FlushCounter] Flushed #{map_size(pending)} counters (#{total} increments)")
          %{state | total_flushed: state.total_flushed + total}

        {:error, reason} ->
          Logger.error("[FlushCounter] Flush failed, re-queueing", reason: inspect(reason))
          Enum.each(entries, fn {key, count} ->
            :ets.update_counter(table, key, {2, count}, {key, 0})
          end)
          state
      end
    end
  end

  defp maybe_trigger_flush(table) do
    if :ets.info(table, :size) >= @default_max_drift do
      GenServer.cast(__MODULE__, :flush_async)
    end
  end

  @impl GenServer
  def handle_cast(:flush_async, state) do
    {:noreply, do_flush(state)}
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)
end
```
