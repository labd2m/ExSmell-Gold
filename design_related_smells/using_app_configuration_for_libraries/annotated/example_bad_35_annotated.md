# Annotated Example — Bad Code

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `RateLimiter.check/1`
- **Affected function(s):** `check/1`, `record_hit/1`, `reset/1`
- **Short explanation:** The library reads `:window_seconds`, `:max_requests`, and `:backend` from the global `Application` environment instead of accepting them as parameters. An application that needs different rate limits for different endpoints (e.g., 10 req/min for login, 100 req/min for search) cannot do so without separate global config blocks or monkey-patching the global state.

```elixir
defmodule RateLimiter do
  @moduledoc """
  A library for enforcing request rate limits using a sliding-window counter.

  Supports ETS and Redis backends for storing hit counters. Designed for
  use in Phoenix plugs and service-layer guards.

  Application configuration:

      config :rate_limiter,
        window_seconds: 60,
        max_requests:   100,
        backend:        :ets,       # :ets | :redis
        key_prefix:     "rl:",
        burst_factor:   1.5
  """

  require Logger

  @doc """
  Checks whether the given key (usually IP or user ID) has exceeded its limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limited, reset_in_seconds}`.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because window_seconds, max_requests, backend,
  # key_prefix, and burst_factor are all read from Application.fetch_env!/2
  # instead of being passed as parameters. A library consumer cannot apply
  # different limits to different routes or operations in the same application.
  def check(key) when is_binary(key) do
    window_seconds = Application.fetch_env!(:rate_limiter, :window_seconds)
    max_requests   = Application.fetch_env!(:rate_limiter, :max_requests)
    backend        = Application.fetch_env!(:rate_limiter, :backend)
    key_prefix     = Application.fetch_env!(:rate_limiter, :key_prefix)
    burst_factor   = Application.fetch_env!(:rate_limiter, :burst_factor)
  # VALIDATION: SMELL END

    full_key     = "#{key_prefix}#{key}"
    burst_limit  = trunc(max_requests * burst_factor)

    {count, window_start} = get_count(backend, full_key, window_seconds)

    cond do
      count >= burst_limit ->
        reset_in = window_start + window_seconds - System.system_time(:second)
        Logger.warning("[RateLimiter] Burst limit hit for #{key}: #{count}/#{burst_limit}")
        {:error, :rate_limited, max(0, reset_in)}

      count >= max_requests ->
        reset_in = window_start + window_seconds - System.system_time(:second)
        {:error, :rate_limited, max(0, reset_in)}

      true ->
        :ok
    end
  end

  @doc """
  Records a hit for the given key and returns the new hit count.
  """
  def record_hit(key) when is_binary(key) do
    window_seconds = Application.fetch_env!(:rate_limiter, :window_seconds)
    backend        = Application.fetch_env!(:rate_limiter, :backend)
    key_prefix     = Application.fetch_env!(:rate_limiter, :key_prefix)

    full_key = "#{key_prefix}#{key}"
    increment_count(backend, full_key, window_seconds)
  end

  @doc """
  Atomically checks and records a hit in one operation.

  Returns `:ok` and records the hit, or `{:error, :rate_limited, reset_in}`.
  """
  def check_and_record(key) when is_binary(key) do
    case check(key) do
      :ok ->
        record_hit(key)
        :ok

      error ->
        error
    end
  end

  @doc """
  Resets the rate limit counter for a given key.
  """
  def reset(key) when is_binary(key) do
    backend    = Application.fetch_env!(:rate_limiter, :backend)
    key_prefix = Application.fetch_env!(:rate_limiter, :key_prefix)

    full_key = "#{key_prefix}#{key}"
    delete_count(backend, full_key)
    :ok
  end

  @doc """
  Returns the current hit count and the number of seconds until the window resets.
  """
  def status(key) when is_binary(key) do
    window_seconds = Application.fetch_env!(:rate_limiter, :window_seconds)
    max_requests   = Application.fetch_env!(:rate_limiter, :max_requests)
    backend        = Application.fetch_env!(:rate_limiter, :backend)
    key_prefix     = Application.fetch_env!(:rate_limiter, :key_prefix)

    full_key             = "#{key_prefix}#{key}"
    {count, window_start} = get_count(backend, full_key, window_seconds)
    reset_in             = window_start + window_seconds - System.system_time(:second)

    %{
      key:            key,
      count:          count,
      limit:          max_requests,
      remaining:      max(0, max_requests - count),
      reset_in:       max(0, reset_in),
      window_seconds: window_seconds
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_count(:ets, key, window_seconds) do
    now          = System.system_time(:second)
    window_start = now - rem(now, window_seconds)

    case :ets.lookup(:rate_limiter_table, key) do
      [{^key, count, stored_start}] when stored_start == window_start ->
        {count, window_start}

      _ ->
        {0, window_start}
    end
  end

  defp get_count(:redis, _key, window_seconds) do
    now          = System.system_time(:second)
    window_start = now - rem(now, window_seconds)
    {0, window_start}
  end

  defp increment_count(:ets, key, window_seconds) do
    now          = System.system_time(:second)
    window_start = now - rem(now, window_seconds)

    new_count =
      case :ets.lookup(:rate_limiter_table, key) do
        [{^key, count, ^window_start}] ->
          count + 1

        _ ->
          1
      end

    :ets.insert(:rate_limiter_table, {key, new_count, window_start})
    new_count
  end

  defp increment_count(:redis, _key, _window_seconds), do: 1

  defp delete_count(:ets, key), do: :ets.delete(:rate_limiter_table, key)
  defp delete_count(:redis, _key), do: :ok
end
```
