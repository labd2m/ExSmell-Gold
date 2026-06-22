```elixir
defmodule Cache.LayeredStore do
  @moduledoc """
  Two-level cache combining a fast in-process ETS L1 layer with a Redis-backed L2 layer.
  Reads fall through from L1 to L2 and populate L1 on a cache hit. Writes propagate to both layers.
  """

  alias Cache.{EtsLayer, RedisLayer}

  @type cache_key :: String.t()
  @type cache_value :: term()
  @type ttl_seconds :: pos_integer()

  @default_l1_ttl 60
  @default_l2_ttl 3600

  @spec get(cache_key()) :: {:ok, cache_value()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    case EtsLayer.get(key) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> fetch_from_l2_and_populate(key)
    end
  end

  @spec put(cache_key(), cache_value(), keyword()) :: :ok | {:error, String.t()}
  def put(key, value, opts \\ []) when is_binary(key) do
    l1_ttl = Keyword.get(opts, :l1_ttl, @default_l1_ttl)
    l2_ttl = Keyword.get(opts, :l2_ttl, @default_l2_ttl)

    with :ok <- EtsLayer.put(key, value, l1_ttl),
         :ok <- RedisLayer.put(key, value, l2_ttl) do
      :ok
    end
  end

  @spec delete(cache_key()) :: :ok
  def delete(key) when is_binary(key) do
    EtsLayer.delete(key)
    RedisLayer.delete(key)
    :ok
  end

  @spec invalidate_prefix(String.t()) :: {:ok, non_neg_integer()}
  def invalidate_prefix(prefix) when is_binary(prefix) do
    EtsLayer.invalidate_prefix(prefix)
    RedisLayer.invalidate_prefix(prefix)
  end

  @spec warm(cache_key(), (() -> cache_value()), keyword()) :: {:ok, cache_value()} | {:error, String.t()}
  def warm(key, loader_fn, opts \\ []) when is_binary(key) and is_function(loader_fn, 0) do
    case get(key) do
      {:ok, cached} ->
        {:ok, cached}

      {:error, :not_found} ->
        value = loader_fn.()
        case put(key, value, opts) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec get_many([cache_key()]) :: %{cache_key() => cache_value()}
  def get_many(keys) when is_list(keys) do
    {hits, misses} = partition_l1_results(keys)
    l2_hits = fetch_l2_batch(misses)
    Map.merge(hits, l2_hits)
  end

  @spec fetch_from_l2_and_populate(cache_key()) :: {:ok, cache_value()} | {:error, :not_found}
  defp fetch_from_l2_and_populate(key) do
    case RedisLayer.get(key) do
      {:ok, value} ->
        EtsLayer.put(key, value, @default_l1_ttl)
        {:ok, value}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec partition_l1_results([cache_key()]) :: {%{cache_key() => cache_value()}, [cache_key()]}
  defp partition_l1_results(keys) do
    Enum.reduce(keys, {%{}, []}, fn key, {hits, misses} ->
      case EtsLayer.get(key) do
        {:ok, value} -> {Map.put(hits, key, value), misses}
        {:error, :not_found} -> {hits, [key | misses]}
      end
    end)
  end

  @spec fetch_l2_batch([cache_key()]) :: %{cache_key() => cache_value()}
  defp fetch_l2_batch([]), do: %{}

  defp fetch_l2_batch(keys) do
    keys
    |> RedisLayer.get_many()
    |> Enum.reduce(%{}, fn {key, result}, acc ->
      case result do
        {:ok, value} ->
          EtsLayer.put(key, value, @default_l1_ttl)
          Map.put(acc, key, value)

        {:error, :not_found} ->
          acc
      end
    end)
  end
end
```
