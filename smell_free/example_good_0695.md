```elixir
defmodule Ops.LogSampler do
  @moduledoc """
  Reduces log volume on high-traffic paths by sampling log calls at a
  configurable rate per message key. The sampler is backed by an ETS
  counter table so sampling decisions are O(1) and lock-free on reads.
  A periodic sweep resets counters to prevent perpetual suppression of
  recurring messages.
  """

  use GenServer

  @table :log_sampler_counters
  @sweep_interval_ms :timer.seconds(60)
  @default_sample_every 100

  @type message_key :: String.t()

  @doc "Starts the log sampler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns true when the message identified by `key` should be logged.
  The first call for a key always returns true. Subsequent calls return
  true once every `sample_every` invocations.
  """
  @spec sample?(message_key(), pos_integer()) :: boolean()
  def sample?(key, sample_every \ @default_sample_every)
      when is_binary(key) and is_integer(sample_every) and sample_every > 0 do
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    rem(count, sample_every) == 1
  end

  @doc """
  Wraps a log call: executes `log_fn` only when `sample?/2` returns true
  for `key`. Returns `:sampled` when skipped, `:logged` when emitted.
  """
  @spec maybe_log(message_key(), pos_integer(), (-> :ok)) :: :logged | :sampled
  def maybe_log(key, sample_every \ @default_sample_every, log_fn)
      when is_function(log_fn, 0) do
    if sample?(key, sample_every) do
      log_fn.()
      :logged
    else
      :sampled
    end
  end

  @doc "Returns the current hit count for `key`."
  @spec hit_count(message_key()) :: non_neg_integer()
  def hit_count(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  @doc "Resets the counter for `key` to zero."
  @spec reset(message_key()) :: :ok
  def reset(key) when is_binary(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Returns the total number of tracked message keys."
  @spec tracked_key_count() :: non_neg_integer()
  def tracked_key_count, do: :ets.info(@table, :size)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    Process.send_after(self(), :sweep, sweep_interval)
    {:ok, %{sweep_interval: sweep_interval}}
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep_interval: interval} = state) do
    :ets.delete_all_objects(@table)
    Process.send_after(self(), :sweep, interval)
    {:noreply, state}
  end
end
```
