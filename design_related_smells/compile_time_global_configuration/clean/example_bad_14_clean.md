```elixir
defmodule Cache.RedisStore do
  @moduledoc """
  Provides a typed key-value cache backed by Redis. All cached values are
  serialised as JSON. Supports per-entry TTLs, namespace-level invalidation,
  and a fetch-on-miss callback pattern.
  """

  require Logger

  @redis_key_separator ":"
  @serialisation_version 1

  @default_ttl_seconds Application.fetch_env!(:cache, :default_ttl_seconds)

  @type cache_key :: String.t()
  @type namespace :: String.t()

  @doc """
  Stores `value` under `key` in Redis, serialising it as versioned JSON.

  ## Parameters
    - `key` - The fully qualified cache key.
    - `value` - Any JSON-serialisable Elixir term.
    - `ttl_seconds` - Time-to-live; defaults to #{inspect(:default_ttl_seconds)}.
  """
  @spec put(cache_key(), term(), pos_integer()) :: :ok | {:error, term()}
  def put(key, value, ttl_seconds \\ @default_ttl_seconds) when is_binary(key) do
    envelope = %{v: @serialisation_version, data: value, cached_at: System.system_time(:second)}

    case Jason.encode(envelope) do
      {:ok, json} ->
        case Redix.command(:redix, ["SET", key, json, "EX", to_string(ttl_seconds)]) do
          {:ok, "OK"} ->
            Logger.debug("Cache PUT key=#{key} ttl=#{ttl_seconds}")
            :ok

          {:error, reason} ->
            Logger.error("Cache PUT failed key=#{key} reason=#{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Cache serialisation failed key=#{key} reason=#{inspect(reason)}")
        {:error, {:serialisation_error, reason}}
    end
  end

  @doc """
  Retrieves the value stored at `key`. Returns `{:ok, value}`, `{:ok, nil}` on
  miss, or `{:error, reason}` on failure.
  """
  @spec get(cache_key()) :: {:ok, term() | nil} | {:error, term()}
  def get(key) when is_binary(key) do
    case Redix.command(:redix, ["GET", key]) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"data" => data}} -> {:ok, data}
          {:error, _} -> {:error, :corrupted}
        end

      {:error, reason} ->
        Logger.error("Cache GET failed key=#{key} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetches the value from the cache if present, otherwise calls `fetch_fn/0`
  to compute and store it, then returns the fresh value.

  ## Parameters
    - `key` - The cache key.
    - `ttl_seconds` - TTL for newly computed values; defaults to the configured default.
    - `fetch_fn` - Zero-arity function returning `{:ok, value}` or `{:error, reason}`.
  """
  @spec get_or_fetch(cache_key(), pos_integer(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def get_or_fetch(key, ttl_seconds \\ @default_ttl_seconds, fetch_fn)
      when is_binary(key) and is_function(fetch_fn, 0) do
    case get(key) do
      {:ok, nil} ->
        Logger.debug("Cache MISS key=#{key}")

        case fetch_fn.() do
          {:ok, value} ->
            put(key, value, ttl_seconds)
            {:ok, value}

          {:error, _} = err ->
            err
        end

      {:ok, value} ->
        Logger.debug("Cache HIT key=#{key}")
        {:ok, value}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Deletes all keys belonging to `namespace` by scanning for the pattern
  `<namespace>:*`. Uses SCAN to avoid blocking the Redis server.
  """
  @spec invalidate_namespace(namespace()) :: {:ok, non_neg_integer()} | {:error, term()}
  def invalidate_namespace(namespace) when is_binary(namespace) do
    pattern = namespace <> @redis_key_separator <> "*"
    Logger.info("Invalidating cache namespace=#{namespace}")
    scan_and_delete(pattern, "0", 0)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp scan_and_delete(pattern, cursor, count) do
    case Redix.command(:redix, ["SCAN", cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, [next_cursor, keys]} ->
        unless Enum.empty?(keys) do
          Redix.command(:redix, ["DEL" | keys])
        end

        new_count = count + length(keys)

        if next_cursor == "0" do
          {:ok, new_count}
        else
          scan_and_delete(pattern, next_cursor, new_count)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```
