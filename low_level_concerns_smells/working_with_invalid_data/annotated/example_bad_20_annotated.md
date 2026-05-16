# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `CacheStore.put/4`, where `ttl_seconds` is passed to `DateTime.add/3`
- **Affected function(s):** `put/4`
- **Short explanation:** The `ttl_seconds` parameter is forwarded directly to `DateTime.add/3` to compute the expiry timestamp. No validation is performed to ensure it is an integer before the call. If a caller passes a string such as `"300"` — common when the TTL is read from an application config or environment variable — `DateTime.add/3` raises a `FunctionClauseError` inside the DateTime module, giving no indication that the problem originated at the public `put/4` boundary.

```elixir
defmodule MyApp.Cache.CacheStore do
  @moduledoc """
  Application-level cache backed by ETS with optional Redis replication.
  Supports namespaced keys, TTL-based expiry, and tag-based invalidation.
  """

  require Logger

  alias MyApp.Cache.{EtsBackend, RedisBackend, TagRegistry}

  @default_ttl_seconds 300
  @max_ttl_seconds 86_400
  @cleanup_interval_ms 60_000
  @namespace_separator ":"

  @type put_opts :: [
          ttl_seconds: pos_integer(),
          tags: [String.t()],
          replicate: boolean(),
          namespace: String.t()
        ]

  @spec put(String.t(), term(), String.t(), put_opts()) :: :ok | {:error, atom()}
  def put(key, value, namespace, opts \\ []) do
    tags = Keyword.get(opts, :tags, [])
    replicate = Keyword.get(opts, :replicate, false)
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    namespaced_key = build_key(namespace, key)
    now = DateTime.utc_now()

    # VALIDATION: SMELL START - Working with invalid data
    # VALIDATION: This is a smell because `ttl_seconds` is passed directly to
    # VALIDATION: `DateTime.add/3` without checking it is an integer.
    # VALIDATION: If a caller extracts this value from application config as a
    # VALIDATION: raw string (e.g. Application.get_env(:my_app, :cache_ttl) before
    # VALIDATION: parsing), `DateTime.add/3` will raise a FunctionClauseError
    # VALIDATION: deep inside the DateTime module with no mention of this function.
    expires_at = DateTime.add(now, ttl_seconds, :second)
    # VALIDATION: SMELL END

    entry = %{
      key: namespaced_key,
      value: value,
      inserted_at: now,
      expires_at: expires_at,
      tags: tags
    }

    with :ok <- EtsBackend.insert(namespaced_key, entry),
         :ok <- register_tags(namespaced_key, tags),
         :ok <- maybe_replicate(entry, replicate) do
      Logger.debug("Cache put: key=#{namespaced_key} ttl=#{ttl_seconds}s tags=#{inspect(tags)}")
      :ok
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, term()} | {:error, :miss} | {:error, :expired}
  def get(key, namespace) do
    namespaced_key = build_key(namespace, key)

    case EtsBackend.lookup(namespaced_key) do
      {:ok, entry} ->
        if DateTime.compare(DateTime.utc_now(), entry.expires_at) == :lt do
          {:ok, entry.value}
        else
          EtsBackend.delete(namespaced_key)
          {:error, :expired}
        end

      {:error, :not_found} ->
        {:error, :miss}
    end
  end

  @spec delete(String.t(), String.t()) :: :ok
  def delete(key, namespace) do
    namespaced_key = build_key(namespace, key)
    EtsBackend.delete(namespaced_key)
    TagRegistry.remove_key(namespaced_key)
    :ok
  end

  @spec invalidate_by_tag(String.t()) :: {:ok, integer()}
  def invalidate_by_tag(tag) do
    keys = TagRegistry.keys_for_tag(tag)

    Enum.each(keys, fn key ->
      EtsBackend.delete(key)
    end)

    TagRegistry.remove_tag(tag)
    Logger.info("Cache invalidated by tag=#{tag}: #{length(keys)} entries removed")
    {:ok, length(keys)}
  end

  @spec fetch_or_store(String.t(), String.t(), put_opts(), (-> term())) ::
          {:ok, term()} | {:error, atom()}
  def fetch_or_store(key, namespace, opts, compute_fn) do
    case get(key, namespace) do
      {:ok, value} ->
        {:ok, value}

      {:error, _} ->
        value = compute_fn.()
        put(key, value, namespace, opts)
        {:ok, value}
    end
  end

  @spec cleanup_expired() :: {:ok, integer()}
  def cleanup_expired do
    now = DateTime.utc_now()
    all_keys = EtsBackend.all_keys()

    expired =
      Enum.filter(all_keys, fn key ->
        case EtsBackend.lookup(key) do
          {:ok, entry} -> DateTime.compare(now, entry.expires_at) != :lt
          _ -> false
        end
      end)

    Enum.each(expired, &EtsBackend.delete/1)
    {:ok, length(expired)}
  end

  # Private helpers

  defp build_key(namespace, key) do
    "#{namespace}#{@namespace_separator}#{key}"
  end

  defp register_tags(_key, []), do: :ok

  defp register_tags(key, tags) do
    Enum.each(tags, &TagRegistry.register(key, &1))
    :ok
  end

  defp maybe_replicate(entry, true), do: RedisBackend.replicate(entry)
  defp maybe_replicate(_entry, false), do: :ok
end
```
