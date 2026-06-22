```elixir
defmodule Infra.Cache.LayeredStore do
  @moduledoc """
  A two-layer cache providing fast in-process ETS lookup backed by a
  distributed Redis store.

  Reads check the local ETS layer first, falling back to Redis and
  populating the local layer on miss. Writes propagate to both layers.
  """

  use GenServer, restart: :permanent

  alias Infra.Cache.{RedisClient, LocalLayer}

  @default_local_ttl_seconds 60
  @default_remote_ttl_seconds 3_600

  @type cache_key :: String.t()
  @type cache_value :: term()

  @type get_result :: {:ok, cache_value()} | {:error, :not_found}

  @doc """
  Starts the layered cache store under a supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Retrieves a value by key, checking local cache then Redis.
  """
  @spec get(cache_key()) :: get_result()
  def get(key) when is_binary(key) do
    case LocalLayer.get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        GenServer.call(__MODULE__, {:fetch_from_remote, key})
    end
  end

  @doc """
  Stores a value in both the local ETS layer and Redis.
  """
  @spec put(cache_key(), cache_value(), keyword()) :: :ok
  def put(key, value, opts \\ []) when is_binary(key) do
    local_ttl = Keyword.get(opts, :local_ttl, @default_local_ttl_seconds)
    remote_ttl = Keyword.get(opts, :remote_ttl, @default_remote_ttl_seconds)

    GenServer.cast(__MODULE__, {:put, key, value, local_ttl, remote_ttl})
  end

  @doc """
  Invalidates a key from both the local and remote cache layers.
  """
  @spec invalidate(cache_key()) :: :ok
  def invalidate(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:invalidate, key})
  end

  @doc """
  Returns hit/miss statistics for the local cache layer.
  """
  @spec local_stats() :: %{hits: non_neg_integer(), misses: non_neg_integer()}
  def local_stats do
    LocalLayer.stats()
  end

  @impl GenServer
  def init(opts) do
    redis_url = Keyword.fetch!(opts, :redis_url)
    {:ok, redis_conn} = RedisClient.connect(redis_url)
    LocalLayer.init()
    {:ok, %{redis: redis_conn}}
  end

  @impl GenServer
  def handle_call({:fetch_from_remote, key}, _from, %{redis: redis} = state) do
    result =
      case RedisClient.get(redis, key) do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, encoded} ->
          value = deserialise(encoded)
          LocalLayer.put(key, value, @default_local_ttl_seconds)
          {:ok, value}

        {:error, _reason} ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:put, key, value, local_ttl, remote_ttl}, %{redis: redis} = state) do
    LocalLayer.put(key, value, local_ttl)
    RedisClient.set(redis, key, serialise(value), remote_ttl)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:invalidate, key}, %{redis: redis} = state) do
    LocalLayer.delete(key)
    RedisClient.delete(redis, key)
    {:noreply, state}
  end

  defp serialise(value), do: :erlang.term_to_binary(value) |> Base.encode64()

  defp deserialise(encoded) do
    encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end
end
```
