```elixir
defmodule Cache.RegionalStore do
  @moduledoc """
  A supervised GenServer providing a per-region in-memory key-value cache
  with TTL expiry. Each region runs its own isolated store process,
  started on demand by a DynamicSupervisor.
  """

  use GenServer

  @sweep_interval_ms 60_000

  @type region :: String.t()
  @type cache_key :: String.t()
  @type cache_entry :: %{value: term(), expires_at: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    region = Keyword.fetch!(opts, :region)
    GenServer.start_link(__MODULE__, opts, name: via(region))
  end

  @spec ensure_started(region()) :: :ok
  def ensure_started(region) when is_binary(region) do
    case DynamicSupervisor.start_child(
           Cache.RegionSupervisor,
           {__MODULE__, [region: region]}
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @spec get(region(), cache_key()) :: {:ok, term()} | {:error, :not_found | :expired}
  def get(region, key) when is_binary(region) and is_binary(key) do
    ensure_started(region)
    GenServer.call(via(region), {:get, key})
  end

  @spec put(region(), cache_key(), term(), pos_integer()) :: :ok
  def put(region, key, value, ttl_seconds)
      when is_binary(region) and is_binary(key) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    ensure_started(region)
    GenServer.cast(via(region), {:put, key, value, ttl_seconds})
  end

  @spec delete(region(), cache_key()) :: :ok
  def delete(region, key) when is_binary(region) and is_binary(key) do
    ensure_started(region)
    GenServer.cast(via(region), {:delete, key})
  end

  @spec flush(region()) :: :ok
  def flush(region) when is_binary(region) do
    ensure_started(region)
    GenServer.call(via(region), :flush)
  end

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{entries: %{}}}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, state) do
    result = lookup_entry(state.entries, key)
    {:reply, result, state}
  end

  def handle_call(:flush, _from, state) do
    {:reply, :ok, %{state | entries: %{}}}
  end

  @impl GenServer
  def handle_cast({:put, key, value, ttl_seconds}, state) do
    expires_at = System.monotonic_time(:second) + ttl_seconds
    entry = %{value: value, expires_at: expires_at}
    {:noreply, put_in(state, [:entries, key], entry)}
  end

  def handle_cast({:delete, key}, state) do
    {:noreply, update_in(state, [:entries], &Map.delete(&1, key))}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    fresh = Map.reject(state.entries, fn {_, entry} -> entry.expires_at <= now end)
    schedule_sweep()
    {:noreply, %{state | entries: fresh}}
  end

  @spec lookup_entry(%{cache_key() => cache_entry()}, cache_key()) ::
          {:ok, term()} | {:error, :not_found | :expired}
  defp lookup_entry(entries, key) do
    case Map.fetch(entries, key) do
      :error ->
        {:error, :not_found}

      {:ok, %{expires_at: expires_at, value: value}} ->
        now = System.monotonic_time(:second)

        if expires_at > now do
          {:ok, value}
        else
          {:error, :expired}
        end
    end
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  @spec via(region()) :: {:via, Registry, {Cache.RegionRegistry, region()}}
  defp via(region), do: {:via, Registry, {Cache.RegionRegistry, region}}
end
```
