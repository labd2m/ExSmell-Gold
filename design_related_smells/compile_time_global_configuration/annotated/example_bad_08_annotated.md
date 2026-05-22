# Annotated Bad Example 08

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@max_requests_per_window` defined at the top of `RateLimiter.Bucket`
- **Affected function(s):** `check_rate/2`, `reset_bucket/1`
- **Short explanation:** `Application.fetch_env!/2` is called in the module body to assign the rate-limit ceiling to a module attribute. Module attributes are resolved at compile-time, before the Application Environment is available, which can trigger a warning or `ArgumentError` during compilation.

---

```elixir
defmodule RateLimiter.Bucket do
  @moduledoc """
  Token-bucket rate limiter backed by an ETS table. Clients are identified
  by a string key (e.g. `"ip:192.0.2.1"` or `"user:42"`). Each key gets
  an independent bucket that refills every `:window_ms` milliseconds.
  """

  require Logger

  @window_ms 60_000

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is executed in the
  # VALIDATION: module body to set a module attribute. Module attributes are evaluated
  # VALIDATION: at compile-time; if the :rate_limiter application has not yet been
  # VALIDATION: loaded, Elixir will emit a warning or raise ArgumentError at compile-time.
  @max_requests_per_window Application.fetch_env!(:rate_limiter, :max_requests_per_window)
  # VALIDATION: SMELL END

  @ets_table :rate_limiter_buckets

  @type bucket_key :: String.t()
  @type rate_check_result ::
          {:allow, remaining :: non_neg_integer()}
          | {:deny, retry_after_ms :: non_neg_integer()}

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent
    }
  end

  @doc false
  def start_link do
    :ets.new(@ets_table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    :ignore
  end

  @doc """
  Checks whether the given `key` is within its rate limit and, if so, increments
  its request counter. Returns `{:allow, remaining}` or `{:deny, retry_after_ms}`.

  ## Parameters
    - `key` - A string identifying the caller (IP, user ID, API key, etc.).
    - `cost` - Number of tokens to consume; defaults to `1`.
  """
  @spec check_rate(bucket_key(), pos_integer()) :: rate_check_result()
  def check_rate(key, cost \\ 1) when is_binary(key) and is_integer(cost) and cost > 0 do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@ets_table, key) do
      [{^key, count, window_start}] when now - window_start < @window_ms ->
        if count + cost <= @max_requests_per_window do
          :ets.insert(@ets_table, {key, count + cost, window_start})
          {:allow, @max_requests_per_window - count - cost}
        else
          retry_after = @window_ms - (now - window_start)
          Logger.debug("Rate limit exceeded key=#{key} retry_after_ms=#{retry_after}")
          {:deny, retry_after}
        end

      _ ->
        :ets.insert(@ets_table, {key, cost, now})
        {:allow, @max_requests_per_window - cost}
    end
  end

  @doc """
  Forcibly resets the request counter for `key`. Useful when temporarily
  whitelisting a client or clearing a stuck bucket during debugging.

  ## Parameters
    - `key` - The bucket key to clear.
  """
  @spec reset_bucket(bucket_key()) :: :ok
  def reset_bucket(key) when is_binary(key) do
    :ets.delete(@ets_table, key)
    Logger.info("Rate-limit bucket reset key=#{key}")
    :ok
  end

  @doc """
  Returns the current state of the bucket for `key`, or `:not_found` if no
  activity has been recorded yet.
  """
  @spec bucket_info(bucket_key()) ::
          {:ok, %{count: non_neg_integer(), remaining: non_neg_integer(), window_started_at: integer()}}
          | :not_found
  def bucket_info(key) when is_binary(key) do
    case :ets.lookup(@ets_table, key) do
      [{^key, count, window_start}] ->
        {:ok,
         %{
           count: count,
           remaining: max(@max_requests_per_window - count, 0),
           window_started_at: window_start
         }}

      [] ->
        :not_found
    end
  end

  @doc """
  Returns the configured maximum number of requests allowed per window.
  """
  @spec limit :: pos_integer()
  def limit, do: @max_requests_per_window

  @doc """
  Returns the window duration in milliseconds.
  """
  @spec window_ms :: pos_integer()
  def window_ms, do: @window_ms
end
```
