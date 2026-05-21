# Annotated Example 19

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `CacheStore.put/2`
- **Affected function(s):** `put/2`
- **Short explanation:** `CacheStore.put/2` reads `:default_ttl_seconds` from the application environment instead of accepting a TTL as an optional parameter. This forces every cached value in the system to expire at the same interval, making it impossible to cache short-lived session tokens and long-lived configuration data with different expirations from the same library.

## Code

```elixir
defmodule CacheStore do
  @moduledoc """
  A generic ETS-backed in-memory cache library with time-to-live support.
  Suitable for caching frequently accessed, slowly-changing data such as
  feature flags, remote configurations, and lookup tables.

  Configuration in `config/config.exs`:

      config :cache_store,
        table_name: :app_cache,
        default_ttl_seconds: 300
  """

  @doc """
  Ensures the backing ETS table is created. Must be called during application start.
  """
  def init do
    table = table_name()

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Stores `value` under `key`.

  The entry will be considered expired after `:default_ttl_seconds` as configured
  in the application environment. Returns `:ok`.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because default_ttl_seconds is fetched from the
  # Application Environment rather than being accepted as an optional parameter.
  # Callers that need different cache durations for different data types
  # (e.g., 10 seconds for stock quotes vs. 3600 seconds for country lists)
  # cannot express this without changing the global config.
  def put(key, value) when is_binary(key) do
    ttl = Application.fetch_env!(:cache_store, :default_ttl_seconds)
    expires_at = System.system_time(:second) + ttl
    :ets.insert(table_name(), {key, value, expires_at})
    :ok
  end
  # VALIDATION: SMELL END

  @doc """
  Retrieves the value stored under `key`, or `nil` if absent or expired.
  """
  def get(key) when is_binary(key) do
    now = System.system_time(:second)

    case :ets.lookup(table_name(), key) do
      [{^key, value, expires_at}] when expires_at > now -> value
      _ -> nil
    end
  end

  @doc """
  Fetches an entry, returning `{:ok, value}` or `:miss`.
  """
  def fetch(key) when is_binary(key) do
    case get(key) do
      nil -> :miss
      value -> {:ok, value}
    end
  end

  @doc """
  Removes an entry from the cache. Returns `:ok` even if the key was not present.
  """
  def delete(key) when is_binary(key) do
    :ets.delete(table_name(), key)
    :ok
  end

  @doc """
  Returns `true` if the key exists and has not expired.
  """
  def exists?(key) when is_binary(key) do
    get(key) != nil
  end

  @doc """
  Removes all expired entries from the table. Safe to call periodically.
  """
  def purge_expired do
    now = System.system_time(:second)

    expired_keys =
      table_name()
      |> :ets.tab2list()
      |> Enum.filter(fn {_key, _value, expires_at} -> expires_at <= now end)
      |> Enum.map(fn {key, _, _} -> key end)

    Enum.each(expired_keys, &:ets.delete(table_name(), &1))
    {:ok, length(expired_keys)}
  end

  @doc """
  Returns all non-expired keys currently in the cache.
  """
  def live_keys do
    now = System.system_time(:second)

    table_name()
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, _value, expires_at} -> expires_at > now end)
    |> Enum.map(fn {key, _, _} -> key end)
  end

  @doc """
  Clears all entries from the cache table regardless of TTL.
  """
  def flush do
    :ets.delete_all_objects(table_name())
    :ok
  end

  ## Private helpers

  defp table_name do
    Application.get_env(:cache_store, :table_name, :app_cache)
  end
end
```
