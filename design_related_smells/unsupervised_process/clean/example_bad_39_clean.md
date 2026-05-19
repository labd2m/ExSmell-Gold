```elixir
defmodule CacheWarmer do
  use GenServer

  @moduledoc """
  Periodically refreshes a named cache namespace by fetching fresh data
  from the backing store and writing it to the cache layer.
  """

  defstruct [
    :namespace,
    :ttl_seconds,
    :refresh_interval_ms,
    :loader_fn,
    :last_warmed_at,
    :warm_count,
    :error_count,
    status: :idle
  ]

  def start(%{namespace: ns} = config) do
    GenServer.start(__MODULE__, config, name: via(ns))
  end

  def force_warm(namespace) do
    GenServer.call(via(namespace), :warm, 60_000)
  end

  def stats(namespace) do
    GenServer.call(via(namespace), :stats)
  end

  def pause(namespace) do
    GenServer.cast(via(namespace), :pause)
  end

  def resume(namespace) do
    GenServer.cast(via(namespace), :resume)
  end

  defp via(ns), do: {:via, Registry, {CacheWarmerRegistry, ns}}

  ## Callbacks

  @impl true
  def init(%{namespace: ns, ttl_seconds: ttl, refresh_interval_ms: interval, loader_fn: loader}) do
    state = %__MODULE__{
      namespace: ns,
      ttl_seconds: ttl,
      refresh_interval_ms: interval,
      loader_fn: loader,
      warm_count: 0,
      error_count: 0
    }

    send(self(), :warm)
    {:ok, state}
  end

  @impl true
  def handle_call(:warm, _from, state) do
    {result, new_state} = do_warm(state)
    {:reply, result, new_state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      namespace: state.namespace,
      status: state.status,
      last_warmed_at: state.last_warmed_at,
      warm_count: state.warm_count,
      error_count: state.error_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:pause, state) do
    {:noreply, %{state | status: :paused}}
  end

  def handle_cast(:resume, %{status: :paused} = state) do
    schedule_refresh(state.refresh_interval_ms)
    {:noreply, %{state | status: :idle}}
  end

  def handle_cast(:resume, state), do: {:noreply, state}

  @impl true
  def handle_info(:warm, %{status: :paused} = state) do
    {:noreply, state}
  end

  def handle_info(:warm, state) do
    {_result, new_state} = do_warm(state)
    {:noreply, new_state}
  end

  defp do_warm(state) do
    case state.loader_fn.(state.namespace) do
      {:ok, entries} ->
        Enum.each(entries, fn {key, value} ->
          write_to_cache(state.namespace, key, value, state.ttl_seconds)
        end)

        now = DateTime.utc_now()
        schedule_refresh(state.refresh_interval_ms)

        result = {:ok, length(entries)}
        new_state = %{state | last_warmed_at: now, warm_count: state.warm_count + 1, status: :idle}
        {result, new_state}

      {:error, reason} ->
        schedule_refresh(state.refresh_interval_ms)
        new_state = %{state | error_count: state.error_count + 1}
        {{:error, reason}, new_state}
    end
  end

  defp write_to_cache(namespace, key, value, ttl) do
    full_key = "#{namespace}:#{key}"
    :ets.insert(:app_cache, {full_key, value, System.os_time(:second) + ttl})
  end

  defp schedule_refresh(interval_ms) do
    Process.send_after(self(), :warm, interval_ms)
  end
end

defmodule CacheManager do
  @moduledoc "Manages cache warmers for multiple namespaces."

  def warm(config) do
    case CacheWarmer.start(config) do
      {:ok, _pid} -> {:ok, config.namespace}
      {:error, {:already_started, _}} -> {:ok, config.namespace}
      {:error, reason} -> {:error, reason}
    end
  end

  def invalidate(namespace) do
    CacheWarmer.force_warm(namespace)
  end
end
```
