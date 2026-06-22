```elixir
defmodule RateLimiter.SlidingWindowStore do
  @moduledoc """
  An ETS-backed sliding window rate limiter. Tracks per-key request
  timestamps within a configurable window and enforces request limits.
  """

  use GenServer

  @table :rate_limiter_windows
  @cleanup_interval_ms 30_000

  @type key :: String.t()
  @type policy :: %{max_requests: pos_integer(), window_ms: pos_integer()}
  @type check_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check_and_record(key(), policy()) :: check_result()
  def check_and_record(key, %{max_requests: max, window_ms: window}) when is_binary(key) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window

    timestamps =
      case :ets.lookup(@table, key) do
        [{^key, existing}] -> existing
        [] -> []
      end

    valid = Enum.filter(timestamps, &(&1 >= cutoff))
    count = length(valid)

    if count < max do
      :ets.insert(@table, {key, [now | valid]})
      {:allow, max - count - 1}
    else
      {:deny, next_available_ms(valid, window, now)}
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    evict_stale_keys()
    schedule_cleanup()
    {:noreply, state}
  end

  @spec next_available_ms([integer()], pos_integer(), integer()) :: non_neg_integer()
  defp next_available_ms(timestamps, window_ms, now) do
    oldest = Enum.min(timestamps)
    max(0, oldest + window_ms - now)
  end

  @spec evict_stale_keys() :: :ok
  defp evict_stale_keys do
    cutoff = System.monotonic_time(:millisecond) - 3_600_000

    :ets.tab2list(@table)
    |> Enum.each(fn {key, timestamps} ->
      fresh = Enum.filter(timestamps, &(&1 >= cutoff))

      if Enum.empty?(fresh) do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, fresh})
      end
    end)
  end

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
```
