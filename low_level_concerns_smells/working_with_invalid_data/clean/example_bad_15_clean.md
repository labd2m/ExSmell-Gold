```elixir
defmodule MyApp.API.RateLimiter do
  @moduledoc """
  Enforces per-client request rate limits using a sliding window algorithm
  backed by ETS counters. Supports configurable windows and burst allowances.
  """

  require Logger

  alias MyApp.API.{RateLimitStore, ClientRegistry, RateLimitEvent}

  @default_window_ms 60_000
  @default_max_requests 100
  @burst_multiplier 1.5
  @cleanup_interval_ms 300_000

  @type window_opts :: [
          window_ms: pos_integer(),
          max_requests: pos_integer(),
          allow_burst: boolean(),
          scope: String.t()
        ]

  @type enforcement_result ::
          {:ok, %{remaining: integer(), reset_at: integer()}}
          | {:error, :rate_limited, %{retry_after_ms: integer()}}

  @spec enforce(String.t(), String.t(), window_opts()) :: enforcement_result()
  def enforce(client_id, endpoint, opts \\ []) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    allow_burst = Keyword.get(opts, :allow_burst, false)
    scope = Keyword.get(opts, :scope, "global")
    now_ms = System.system_time(:millisecond)

    max_requests = Keyword.get(opts, :max_requests, @default_max_requests)

    effective_max =
      if allow_burst do
        trunc(max_requests * @burst_multiplier)
      else
        max_requests
      end

    window_key = build_window_key(client_id, endpoint, scope, now_ms, window_ms)
    current_count = RateLimitStore.increment(window_key, window_ms)

    if current_count >= effective_max do
      reset_at = compute_reset_at(window_key, window_ms, now_ms)
      retry_after = max(0, reset_at - now_ms)

      Logger.warning(
        "Rate limit exceeded: client=#{client_id} endpoint=#{endpoint} " <>
          "count=#{current_count} max=#{effective_max}"
      )

      RateLimitEvent.record(client_id, endpoint, :exceeded)

      {:error, :rate_limited, %{retry_after_ms: retry_after, reset_at: reset_at}}
    else
      remaining = effective_max - current_count
      reset_at = compute_reset_at(window_key, window_ms, now_ms)

      {:ok, %{remaining: remaining, reset_at: reset_at, current: current_count}}
    end
  end

  @spec client_status(String.t(), keyword()) :: {:ok, map()}
  def client_status(client_id, opts \\ []) do
    scope = Keyword.get(opts, :scope, "global")

    with {:ok, client} <- ClientRegistry.fetch(client_id) do
      counters = RateLimitStore.fetch_all_counters(client_id, scope)

      {:ok,
       %{
         client_id: client_id,
         tier: client.tier,
         active_windows: map_size(counters),
         counters: counters
       }}
    end
  end

  @spec reset_client(String.t(), String.t()) :: :ok
  def reset_client(client_id, scope \\ "global") do
    Logger.info("Resetting rate limit counters for client=#{client_id} scope=#{scope}")
    RateLimitStore.clear_all(client_id, scope)
  end

  @spec cleanup_expired() :: {:ok, integer()}
  def cleanup_expired do
    deleted = RateLimitStore.delete_expired(System.system_time(:millisecond))
    Logger.debug("Rate limit cleanup: removed #{deleted} expired windows")
    {:ok, deleted}
  end

  # Private helpers

  defp build_window_key(client_id, endpoint, scope, now_ms, window_ms) do
    bucket = div(now_ms, window_ms)
    "rl:#{scope}:#{client_id}:#{endpoint}:#{bucket}"
  end

  defp compute_reset_at(_window_key, window_ms, now_ms) do
    bucket = div(now_ms, window_ms)
    (bucket + 1) * window_ms
  end
end
```
