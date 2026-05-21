# Annotated Example 14

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `RateLimiter.check/1`
- **Affected function(s):** `check/1`
- **Short explanation:** `RateLimiter.check/1` retrieves `:max_requests` and `:window_seconds` from the application environment instead of accepting them as parameters. Because the limit is global, the library cannot be reused with different thresholds for different resource types (e.g., login attempts vs. API calls) within the same application.

## Code

```elixir
defmodule RateLimiter do
  @moduledoc """
  A sliding-window rate-limiting library backed by ETS. Designed to be embedded
  in plug pipelines or Phoenix controllers to throttle inbound requests.

  Configuration in `config/config.exs`:

      config :rate_limiter,
        max_requests: 100,
        window_seconds: 60
  """

  @table_name :rate_limiter_buckets

  @doc """
  Initialises the ETS table used to track request counts.
  Should be called during application startup, typically inside a Supervisor child.
  """
  def init do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Checks whether the given key (e.g., IP address or user ID) has exceeded the
  configured request threshold within the current window.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limited}` otherwise.

  Max requests and window size are read from the application environment:

      config :rate_limiter,
        max_requests: 100,
        window_seconds: 60
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because max_requests and window_seconds are fetched
  # from the Application Environment instead of being passed as function parameters
  # or keyword options. This makes it impossible for the same library to enforce
  # a 10-requests-per-minute limit on the login endpoint and a 1000-requests-per-minute
  # limit on the public feed endpoint without changing global config.
  def check(key) when is_binary(key) do
    max_requests = Application.fetch_env!(:rate_limiter, :max_requests)
    window_seconds = Application.fetch_env!(:rate_limiter, :window_seconds)

    now = System.system_time(:second)
    window_start = now - window_seconds

    prune_stale(key, window_start)
    count = increment(key, now)

    if count > max_requests do
      {:error, :rate_limited}
    else
      :ok
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Resets all recorded hits for the given key. Useful in tests or admin tooling.
  """
  def reset(key) when is_binary(key) do
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Returns the current hit count for the given key within the active window.
  Does not increment the counter.
  """
  def current_count(key) when is_binary(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, timestamps}] -> length(timestamps)
      [] -> 0
    end
  end

  @doc """
  Returns `true` if the given key is currently rate-limited.
  """
  def limited?(key) when is_binary(key) do
    match?({:error, :rate_limited}, check(key))
  end

  ## Private helpers

  defp prune_stale(key, window_start) do
    case :ets.lookup(@table_name, key) do
      [{^key, timestamps}] ->
        fresh = Enum.filter(timestamps, &(&1 >= window_start))
        :ets.insert(@table_name, {key, fresh})

      [] ->
        :ok
    end
  end

  defp increment(key, now) do
    case :ets.lookup(@table_name, key) do
      [{^key, timestamps}] ->
        updated = [now | timestamps]
        :ets.insert(@table_name, {key, updated})
        length(updated)

      [] ->
        :ets.insert(@table_name, {key, [now]})
        1
    end
  end
end
```
