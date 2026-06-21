```elixir
defmodule Traffic.DistributedRateLimiter do
  @moduledoc """
  A cluster-aware rate limiter using Redis sliding window counters via Redix.
  Unlike the in-process token bucket, this implementation is consistent across
  all nodes in the cluster because state lives in Redis rather than a single
  GenServer. The sliding window algorithm counts requests in the past
  `window_ms` milliseconds using a sorted set keyed by client identifier,
  providing accurate enforcement without the boundary burst problem of fixed
  windows.
  """

  require Logger

  @type client_key :: binary()
  @type limit_opts :: [
          limit: pos_integer(),
          window_ms: pos_integer()
        ]

  @default_limit 100
  @default_window_ms 60_000

  @doc """
  Checks whether `client_key` is within its rate limit. Increments the
  request counter atomically using a Lua script for compare-and-set safety.
  Returns `{:ok, remaining}` when the request is allowed, or
  `{:error, :rate_limited}` when the limit is exceeded.
  """
  @spec check(client_key(), limit_opts()) ::
          {:ok, non_neg_integer()} | {:error, :rate_limited}
  def check(client_key, opts \\ []) when is_binary(client_key) do
    limit = Keyword.get(opts, :limit, @default_limit)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    now_ms = System.system_time(:millisecond)
    window_start = now_ms - window_ms
    redis_key = "rl:#{client_key}"

    script = """
    local key = KEYS[1]
    local now = tonumber(ARGV[1])
    local window_start = tonumber(ARGV[2])
    local limit = tonumber(ARGV[3])
    local window_ms = tonumber(ARGV[4])

    redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)
    local count = redis.call('ZCARD', key)

    if count < limit then
      redis.call('ZADD', key, now, now .. ':' .. math.random(1000000))
      redis.call('PEXPIRE', key, window_ms)
      return {1, limit - count - 1}
    else
      return {0, 0}
    end
    """

    case Redix.command(:redix, ["EVAL", script, 1, redis_key,
                                 now_ms, window_start, limit, window_ms]) do
      {:ok, [1, remaining]} ->
        {:ok, remaining}

      {:ok, [0, _]} ->
        {:error, :rate_limited}

      {:error, reason} ->
        Logger.error("Rate limiter Redis error", key: client_key, reason: inspect(reason))
        {:ok, limit}
    end
  end

  @doc """
  Resets the rate limit counter for `client_key` immediately. Intended for
  use in tests and operator tooling, not application hot paths.
  """
  @spec reset(client_key()) :: :ok | {:error, term()}
  def reset(client_key) when is_binary(client_key) do
    case Redix.command(:redix, ["DEL", "rl:#{client_key}"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the current request count for `client_key` within the active window.
  Does not modify the counter; read-only diagnostic helper.
  """
  @spec current_count(client_key(), limit_opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def current_count(client_key, opts \\ []) when is_binary(client_key) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    now_ms = System.system_time(:millisecond)
    window_start = now_ms - window_ms
    redis_key = "rl:#{client_key}"

    case Redix.pipeline(:redix, [
           ["ZREMRANGEBYSCORE", redis_key, "-inf", window_start],
           ["ZCARD", redis_key]
         ]) do
      {:ok, [_, count]} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the child spec for Redix. Add to your application supervisor
  before this module is used.
  """
  @spec redix_child_spec() :: Supervisor.child_spec()
  def redix_child_spec do
    url = Application.fetch_env!(:my_app, :redis_url)
    {Redix, url: url, name: :redix}
  end
end
```
