# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@max_requests` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `check_rate/2`, `consume/2`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to set `@max_requests`. At that point the application environment is not yet available, so Elixir may raise an `ArgumentError` or emit a deprecation warning. The integer is baked into the beam file, so the limit cannot be tuned in production without a full recompile.

---

```elixir
defmodule RateLimiter.TokenBucket do
  @moduledoc """
  A per-key token-bucket rate limiter backed by an ETS table.
  The bucket capacity and refill rate are driven by application configuration.
  Call `check_rate/2` to test whether a key is below the limit without
  consuming a token, or `consume/2` to atomically decrement and respond.
  """

  use GenServer

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is evaluated
  # VALIDATION: at module-compilation time. The :rate_limiter application is
  # VALIDATION: almost certainly not loaded at that point, so Elixir will raise
  # VALIDATION:   ** (ArgumentError) could not fetch application environment
  # VALIDATION: Even when it does not crash, the integer is embedded in the
  # VALIDATION: compiled bytecode and cannot be changed at runtime.
  @max_requests Application.fetch_env!(:rate_limiter, :max_requests_per_window)
  # VALIDATION: SMELL END

  @window_ms 60_000
  @cleanup_interval_ms 120_000
  @table __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check_rate(String.t(), String.t()) :: {:allow, integer()} | {:deny, 0}
  def check_rate(namespace, key) when is_binary(namespace) and is_binary(key) do
    bucket_key = bucket_key(namespace, key)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, bucket_key) do
      [] ->
        {:allow, @max_requests - 1}

      [{^bucket_key, count, window_start}] ->
        if now - window_start >= @window_ms do
          {:allow, @max_requests - 1}
        else
          remaining = @max_requests - count
          if remaining > 0, do: {:allow, remaining}, else: {:deny, 0}
        end
    end
  end

  @spec consume(String.t(), String.t()) :: {:allow, integer()} | {:deny, 0}
  def consume(namespace, key) when is_binary(namespace) and is_binary(key) do
    bucket_key = bucket_key(namespace, key)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, bucket_key) do
      [] ->
        :ets.insert(@table, {bucket_key, 1, now})
        {:allow, @max_requests - 1}

      [{^bucket_key, count, window_start}] ->
        if now - window_start >= @window_ms do
          :ets.insert(@table, {bucket_key, 1, now})
          {:allow, @max_requests - 1}
        else
          if count < @max_requests do
            :ets.update_counter(@table, bucket_key, {2, 1})
            {:allow, @max_requests - count - 1}
          else
            Logger.warning("Rate limit exceeded", namespace: namespace, key: key)
            {:deny, 0}
          end
        end
    end
  end

  @spec reset(String.t(), String.t()) :: :ok
  def reset(namespace, key) do
    :ets.delete(@table, bucket_key(namespace, key))
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    schedule_cleanup()
    Logger.info("RateLimiter started", max_requests: @max_requests, window_ms: @window_ms)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_ms

    expired_keys =
      :ets.foldl(
        fn {key, _count, window_start}, acc ->
          if window_start < cutoff, do: [key | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(expired_keys, &:ets.delete(@table, &1))

    Logger.debug("Rate limiter cleanup", removed: length(expired_keys))
    schedule_cleanup()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp bucket_key(namespace, key), do: "#{namespace}:#{key}"

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
```
