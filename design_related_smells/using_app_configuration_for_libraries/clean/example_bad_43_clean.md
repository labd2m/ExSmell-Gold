```elixir
defmodule RateLimiter do
  @moduledoc """
  An in-process rate-limiting library backed by ETS. Implements a
  sliding-window counter strategy suitable for API endpoints, login
  throttling, and webhook delivery guards.

  Configuration (config/config.exs):

      config :rate_limiter,
        window_seconds: 60,
        max_requests: 100
  """

  require Logger

  @table_name :rate_limiter_counters

  @doc """
  Starts the underlying ETS table. Must be called during application startup,
  e.g. in a Supervisor's `init/1` callback or an Application module.
  """
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Checks whether the given key has exceeded the configured rate limit.

  Returns `:allow` if the request is within the allowed window and count,
  or `{:deny, retry_after_seconds}` if the limit has been exceeded.
  """
  @spec check(String.t(), String.t()) :: :allow | {:deny, non_neg_integer()}
  def check(key, bucket \\ "default") when is_binary(key) do
    window_seconds = Application.fetch_env!(:rate_limiter, :window_seconds)
    max_requests = Application.fetch_env!(:rate_limiter, :max_requests)

    now = System.os_time(:second)
    full_key = "#{bucket}:#{key}"

    {count, window_start} = fetch_counter(@table_name, full_key, now)

    elapsed = now - window_start
    remaining_window = max(window_seconds - elapsed, 0)

    cond do
      elapsed >= window_seconds ->
        reset_counter(@table_name, full_key, now)
        :allow

      count < max_requests ->
        increment_counter(@table_name, full_key)
        :allow

      true ->
        Logger.warning("[RateLimiter] key=#{full_key} exceeded limit=#{max_requests} retry_after=#{remaining_window}s")
        {:deny, remaining_window}
    end
  end

  @doc """
  Increments the counter for a key without performing a limit check.
  Useful for one-way accounting (e.g., tracking outbound webhook calls).
  """
  @spec increment(String.t(), String.t()) :: non_neg_integer()
  def increment(key, bucket \\ "default") when is_binary(key) do
    window_seconds = Application.fetch_env!(:rate_limiter, :window_seconds)
    now = System.os_time(:second)
    full_key = "#{bucket}:#{key}"

    {count, window_start} = fetch_counter(@table_name, full_key, now)

    if now - window_start >= window_seconds do
      reset_counter(@table_name, full_key, now)
      1
    else
      increment_counter(@table_name, full_key)
      count + 1
    end
  end

  @doc """
  Returns the current request count and remaining quota for a key.
  """
  @spec status(String.t(), String.t()) :: %{count: integer(), remaining: integer(), resets_in: integer()}
  def status(key, bucket \\ "default") when is_binary(key) do
    window_seconds = Application.fetch_env!(:rate_limiter, :window_seconds)
    max_requests = Application.fetch_env!(:rate_limiter, :max_requests)

    now = System.os_time(:second)
    full_key = "#{bucket}:#{key}"

    {count, window_start} = fetch_counter(@table_name, full_key, now)
    elapsed = now - window_start

    %{
      count: count,
      remaining: max(max_requests - count, 0),
      resets_in: max(window_seconds - elapsed, 0)
    }
  end

  @doc """
  Clears all counters for a given bucket prefix.
  """
  @spec clear_bucket(String.t()) :: :ok
  def clear_bucket(bucket) when is_binary(bucket) do
    pattern = {:ets.fun2ms(fn {k, _, _} when is_binary(k) -> k end)}
    _ = pattern
    :ets.match_delete(@table_name, {"#{bucket}:_", :_, :_})
    :ok
  end

  # --- Private helpers ---

  defp fetch_counter(table, key, now) do
    case :ets.lookup(table, key) do
      [{^key, count, window_start}] -> {count, window_start}
      [] -> {0, now}
    end
  end

  defp reset_counter(table, key, now) do
    :ets.insert(table, {key, 1, now})
  end

  defp increment_counter(table, key) do
    :ets.update_counter(table, key, {2, 1})
  end
end
```
