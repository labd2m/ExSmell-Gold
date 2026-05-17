```elixir
# ── file: lib/cache/store.ex ─────────────────────────────────────────────────


defmodule Cache.Store do
  @moduledoc """
  Primary key-value cache backed by ETS with optional TTL support.
  Defined in `lib/cache/store.ex`.
  """

  alias Cache.{TTLSweeper, NamespaceRegistry, SerDe}

  @table_name :app_cache
  @default_ttl_seconds 300
  @max_value_bytes 1_048_576

  @type key :: String.t()
  @type ttl_seconds :: pos_integer() | :infinity

  @doc "Retrieve a value from the cache. Returns `{:ok, value}` or `:miss`."
  @spec get(key()) :: {:ok, term()} | :miss
  def get(key) when is_binary(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(@table_name, key)
          :miss
        else
          {:ok, SerDe.deserialise(value)}
        end

      [] ->
        :miss
    end
  end

  @doc "Store a value under `key` with an optional TTL in seconds."
  @spec put(key(), term(), ttl_seconds()) :: :ok | {:error, String.t()}
  def put(key, value, ttl \\ @default_ttl_seconds) when is_binary(key) do
    with {:ok, serialised} <- SerDe.serialise(value),
         :ok <- check_size(serialised) do
      expires_at = compute_expiry(ttl)
      namespace = namespace_of(key)
      :ets.insert(@table_name, {key, serialised, expires_at})
      NamespaceRegistry.track(namespace, key)
      :ok
    end
  end

  @doc "Delete a single cache entry by key."
  @spec delete(key()) :: :ok
  def delete(key) when is_binary(key) do
    :ets.delete(@table_name, key)
    NamespaceRegistry.untrack(namespace_of(key), key)
    :ok
  end

  @doc """
  Fetch a value from the cache, calling `fallback_fn/0` on a miss.
  The result of `fallback_fn` is stored with the given TTL.
  """
  @spec fetch(key(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, fallback_fn, ttl \\ @default_ttl_seconds) do
    case get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case fallback_fn.() do
          {:ok, value} ->
            put(key, value, ttl)
            {:ok, value}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Invalidate all keys belonging to a given namespace prefix."
  @spec invalidate_namespace(String.t()) :: {:ok, non_neg_integer()}
  def invalidate_namespace(namespace) when is_binary(namespace) do
    keys = NamespaceRegistry.keys(namespace)
    Enum.each(keys, &delete/1)
    NamespaceRegistry.clear(namespace)
    {:ok, length(keys)}
  end

  @doc "Flush the entire cache table."
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table_name)
    NamespaceRegistry.clear_all()
    :ok
  end

  defp expired?(:infinity), do: false
  defp expired?(ts), do: System.system_time(:second) >= ts

  defp compute_expiry(:infinity), do: :infinity
  defp compute_expiry(ttl), do: System.system_time(:second) + ttl

  defp namespace_of(key) do
    key |> String.split(":") |> List.first()
  end

  defp check_size(binary) when byte_size(binary) > @max_value_bytes do
    {:error, "Value exceeds max cache size of #{@max_value_bytes} bytes"}
  end

  defp check_size(_binary), do: :ok
end


# ── file: lib/cache/store_warmer.ex ─────────────────────────────────────────────────────


defmodule Cache.Store do
  @moduledoc """
  Proactive cache warming strategies for frequently accessed data.
  """

  alias Cache.WarmingPolicy

  @doc "Warm all registered cache namespaces using their configured loaders."
  @spec warm_all() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def warm_all do
    policies = WarmingPolicy.all()

    results =
      Enum.map(policies, fn policy ->
        {policy.namespace, warm_namespace(policy)}
      end)

    failed = for {ns, {:error, _}} <- results, do: ns

    if failed == [] do
      {:ok, length(policies)}
    else
      {:error, "Failed to warm namespaces: #{Enum.join(failed, ", ")}"}
    end
  end

  @doc "Warm a single namespace by invoking its registered loader."
  @spec warm_namespace(map()) :: :ok | {:error, String.t()}
  def warm_namespace(%{namespace: ns, loader: loader_fn, ttl: ttl}) do
    case loader_fn.() do
      {:ok, entries} when is_list(entries) ->
        Enum.each(entries, fn {key, value} ->
          full_key = "#{ns}:#{key}"
          :ets.insert(:app_cache, {full_key, value, System.system_time(:second) + ttl})
        end)
        :ok

      {:error, reason} ->
        {:error, "Loader failed for #{ns}: #{inspect(reason)}"}
    end
  end

  @doc "Schedule periodic re-warming for a namespace at the given interval."
  @spec schedule_warming(String.t(), pos_integer()) :: {:ok, reference()}
  def schedule_warming(namespace, interval_seconds) do
    ref = :timer.apply_interval(
      interval_seconds * 1_000,
      __MODULE__,
      :warm_namespace,
      [WarmingPolicy.fetch!(namespace)]
    )

    {:ok, ref}
  end
end

```
