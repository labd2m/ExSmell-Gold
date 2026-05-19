# Annotated Example 10 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Cache.WarmingWorker.start/2`
- **Affected function(s):** `start/2`
- **Short explanation:** Each cache namespace gets its own warming GenServer started with `GenServer.start/3` outside any supervision tree. If a warming worker crashes, the cache for that namespace is never refreshed again, causing stale data to serve indefinitely with no observable failure.

```elixir
defmodule Cache.WarmingWorker do
  use GenServer

  @moduledoc """
  Proactively warms and periodically refreshes a named cache partition.
  Coordinates background refresh cycles to prevent cache stampedes by
  using staggered jitter on refresh intervals.
  """

  @default_refresh_interval_ms 300_000
  @jitter_range_ms 30_000

  defstruct [
    :namespace,
    :loader_fn,
    :refresh_interval_ms,
    :last_refresh_at,
    :refresh_count,
    :hit_count,
    :miss_count,
    :store
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` creates a long-running
  # cache warming process outside any supervision tree. Each cache namespace — such
  # as :products, :pricing, or :user_permissions — gets its own process. If one of
  # these crashes (e.g., the loader function raises on a bad DB response), the cache
  # namespace goes cold permanently. There is no supervisor to restart the worker, so
  # stale or absent cache data persists silently.
  def start(namespace, opts \\ []) do
    loader_fn = Keyword.fetch!(opts, :loader)

    state = %__MODULE__{
      namespace: namespace,
      loader_fn: loader_fn,
      refresh_interval_ms: Keyword.get(opts, :interval_ms, @default_refresh_interval_ms),
      last_refresh_at: nil,
      refresh_count: 0,
      hit_count: 0,
      miss_count: 0,
      store: %{}
    }

    GenServer.start(__MODULE__, state, name: via_name(namespace))
  end
  # VALIDATION: SMELL END

  @doc "Fetches a value from the cache, recording a hit or miss."
  def get(namespace, key) do
    GenServer.call(via_name(namespace), {:get, key})
  end

  @doc "Forces an immediate cache refresh outside the normal cycle."
  def force_refresh(namespace) do
    GenServer.cast(via_name(namespace), :force_refresh)
  end

  @doc "Returns current cache metrics for the namespace."
  def metrics(namespace) do
    GenServer.call(via_name(namespace), :metrics)
  end

  @doc "Explicitly warms a subset of keys."
  def warm_keys(namespace, keys) do
    GenServer.cast(via_name(namespace), {:warm_keys, keys})
  end

  ## Callbacks

  @impl true
  def init(state) do
    send(self(), :initial_load)
    {:ok, state}
  end

  @impl true
  def handle_info(:initial_load, state) do
    new_state = do_refresh(state)
    schedule_refresh(new_state.refresh_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(:refresh, state) do
    new_state = do_refresh(state)
    schedule_refresh(new_state.refresh_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.store, key) do
      {:ok, value} ->
        {:reply, {:ok, value}, %{state | hit_count: state.hit_count + 1}}

      :error ->
        {:reply, {:error, :not_found}, %{state | miss_count: state.miss_count + 1}}
    end
  end

  def handle_call(:metrics, _from, state) do
    total = state.hit_count + state.miss_count
    hit_rate = if total > 0, do: state.hit_count / total, else: 0.0

    metrics = %{
      namespace: state.namespace,
      size: map_size(state.store),
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      hit_rate: hit_rate,
      refresh_count: state.refresh_count,
      last_refresh_at: state.last_refresh_at
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_cast(:force_refresh, state) do
    {:noreply, do_refresh(state)}
  end

  def handle_cast({:warm_keys, keys}, state) do
    new_entries = Enum.reduce(keys, %{}, fn key, acc ->
      case apply(state.loader_fn, [key]) do
        {:ok, value} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)

    {:noreply, %{state | store: Map.merge(state.store, new_entries)}}
  end

  defp do_refresh(state) do
    new_store =
      case apply(state.loader_fn, [:all]) do
        {:ok, data} when is_map(data) -> data
        _ -> state.store
      end

    %{
      state
      | store: new_store,
        last_refresh_at: DateTime.utc_now(),
        refresh_count: state.refresh_count + 1
    }
  end

  defp schedule_refresh(interval_ms) do
    jitter = :rand.uniform(@jitter_range_ms)
    Process.send_after(self(), :refresh, interval_ms + jitter)
  end

  defp via_name(namespace) do
    {:via, Registry, {Cache.WarmingRegistry, namespace}}
  end
end
```
