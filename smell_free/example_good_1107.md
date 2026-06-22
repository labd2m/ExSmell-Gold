```elixir
defmodule Plug.RateLimiter do
  @moduledoc """
  A Plug middleware that enforces per-client request rate limits.
  Configuration is accepted as options at `init/1`, allowing the plug
  to be mounted with different policies on different routes.

  Options:
    - `:max_requests` - maximum allowed requests within the window (default: 100)
    - `:window_seconds` - duration of the rate limit window (default: 60)
    - `:key_fn` - arity-1 function mapping a `Plug.Conn` to a string key
  """

  @behaviour Plug

  import Plug.Conn

  @default_max 100
  @default_window 60

  @type options :: [
          max_requests: pos_integer(),
          window_seconds: pos_integer(),
          key_fn: (Plug.Conn.t() -> String.t())
        ]

  @impl Plug
  def init(opts) when is_list(opts) do
    %{
      max_requests: Keyword.get(opts, :max_requests, @default_max),
      window_seconds: Keyword.get(opts, :window_seconds, @default_window),
      key_fn: Keyword.get(opts, :key_fn, &default_key/1)
    }
  end

  @impl Plug
  def call(conn, config) do
    key = config.key_fn.(conn)
    current = RateLimit.Backend.increment(key, config.window_seconds)
    apply_limit(conn, current, config.max_requests)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp apply_limit(conn, current, max) when current <= max do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(max))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max - current))
  end

  defp apply_limit(conn, _current, max) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(max))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> put_resp_header("retry-after", "60")
    |> send_resp(429, ~s({"error":"rate_limit_exceeded"}))
    |> halt()
  end

  defp default_key(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> List.first(conn.remote_ip |> :inet.ntoa() |> to_string())
  end
end

defmodule RateLimit.Backend do
  @moduledoc """
  ETS-backed counter store for the rate limiter plug.
  Each key is stored with a count and a window expiry timestamp.
  """

  @table :rate_limit_counters

  @doc "Ensures the ETS table exists; safe to call multiple times."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
    :ok
  end

  @doc "Increments the counter for a key within a given window and returns the new count."
  @spec increment(String.t(), pos_integer()) :: pos_integer()
  def increment(key, window_seconds) when is_binary(key) and is_integer(window_seconds) do
    ensure_table()
    now = System.os_time(:second)
    window_end = now + window_seconds
    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, 1, window_end})
        1
      [{^key, _count, expires_at}] when expires_at < now ->
        :ets.insert(@table, {key, 1, window_end})
        1
      [{^key, count, expires_at}] ->
        new_count = count + 1
        :ets.insert(@table, {key, new_count, expires_at})
        new_count
    end
  end
end
```
