```elixir
defmodule Cache.ReadThrough do
  @moduledoc """
  A supervised read-through cache backed by ETS with per-entry TTL and
  probabilistic cache stampede protection. When a cache miss occurs during
  a period of high concurrency, only one caller fetches from the origin;
  the rest receive the stale value (if available) or wait for the in-flight
  fetch to complete. This prevents the thundering-herd problem that arises
  when many concurrent requests all miss a recently expired key simultaneously.
  """

  use GenServer

  require Logger

  @table :read_through_cache
  @default_ttl_seconds 300
  @jitter_factor 0.1

  @type cache_key :: term()
  @type fetch_fn :: (() -> {:ok, term()} | {:error, term()})

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached value for `key`, calling `fetch_fn` on a miss to
  populate the cache. `ttl_seconds` controls how long the entry lives.
  Returns `{:ok, value}` or `{:error, reason}`.
  """
  @spec get(cache_key(), fetch_fn(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def get(key, fetch_fn, ttl_seconds \\ @default_ttl_seconds)
      when is_function(fetch_fn, 0) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    case lookup(key) do
      {:hit, value} ->
        {:ok, value}

      {:stale, value} ->
        GenServer.cast(__MODULE__, {:background_refresh, key, fetch_fn, ttl_seconds})
        {:ok, value}

      :miss ->
        GenServer.call(__MODULE__, {:fetch, key, fetch_fn, ttl_seconds})
    end
  end

  @doc """
  Explicitly invalidates `key`. The next `get/3` call will populate it fresh.
  """
  @spec invalidate(cache_key()) :: :ok
  def invalidate(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Returns the number of entries currently held in the cache.
  """
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{in_flight: %{}}}
  end

  @impl GenServer
  def handle_call({:fetch, key, fetch_fn, ttl}, from, state) do
    case Map.get(state.in_flight, key) do
      nil ->
        task = Task.async(fn -> fetch_fn.() end)
        new_state = put_in(state, [:in_flight, key], {task, [from], ttl})
        {:noreply, new_state}

      {_task, waiters, ttl} ->
        new_state = put_in(state, [:in_flight, key], {state.in_flight[key] |> elem(0), [from | waiters], ttl})
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:background_refresh, key, fetch_fn, ttl}, state) do
    unless Map.has_key?(state.in_flight, key) do
      Task.start(fn ->
        case fetch_fn.() do
          {:ok, value} -> store(key, value, ttl)
          {:error, reason} -> Logger.warning("Background cache refresh failed", key: inspect(key), reason: inspect(reason))
        end
      end)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({ref, result}, state) do
    case find_key_by_task_ref(state.in_flight, ref) do
      nil ->
        {:noreply, state}

      key ->
        {_task, waiters, ttl} = Map.get(state.in_flight, key)

        case result do
          {:ok, value} ->
            store(key, value, ttl)
            Enum.each(waiters, &GenServer.reply(&1, {:ok, value}))

          {:error, reason} ->
            Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
        end

        {:noreply, %{state | in_flight: Map.delete(state.in_flight, key)}}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lookup(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when now < expires_at -> {:hit, value}
      [{^key, value, _expires_at}] -> {:stale, value}
      [] -> :miss
    end
  end

  defp store(key, value, ttl_seconds) do
    jitter = trunc(ttl_seconds * @jitter_factor * :rand.uniform())
    expires_at = System.system_time(:second) + ttl_seconds + jitter
    :ets.insert(@table, {key, value, expires_at})
  end

  defp find_key_by_task_ref(in_flight, ref) do
    Enum.find_value(in_flight, fn {key, {task, _waiters, _ttl}} ->
      if task.ref == ref, do: key, else: nil
    end)
  end
end
```
