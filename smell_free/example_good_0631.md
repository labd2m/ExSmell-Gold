```elixir
defmodule Permissions.PolicyCache do
  @moduledoc """
  Caches resolved permission sets for authenticated users to avoid
  repeated database lookups on hot request paths. Cache entries are
  keyed by user ID and expire after a configurable TTL. Entries are
  invalidated explicitly when a user's role or permissions change.
  Reads go directly to ETS for sub-microsecond latency; only writes
  and invalidations pass through the GenServer.
  """

  use GenServer

  @table :permissions_cache
  @default_ttl_ms :timer.minutes(5)

  @type user_id :: String.t()
  @type permission_set :: MapSet.t()

  @doc "Starts the permissions cache."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetches the cached permission set for `user_id`. Returns
  `{:error, :miss}` when the entry is absent or expired.
  """
  @spec fetch(user_id()) :: {:ok, permission_set()} | {:error, :miss}
  def fetch(user_id) when is_binary(user_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, user_id) do
      [{^user_id, permissions, expires_at}] when expires_at > now ->
        {:ok, permissions}

      _ ->
        {:error, :miss}
    end
  end

  @doc "Stores `permissions` for `user_id`. Accepts an optional `ttl_ms` override."
  @spec put(user_id(), permission_set(), keyword()) :: :ok
  def put(user_id, permissions, opts \ [])
      when is_binary(user_id) and is_struct(permissions, MapSet) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    GenServer.cast(__MODULE__, {:put, user_id, permissions, ttl})
  end

  @doc "Removes the cached entry for `user_id`."
  @spec invalidate(user_id()) :: :ok
  def invalidate(user_id) when is_binary(user_id) do
    GenServer.cast(__MODULE__, {:invalidate, user_id})
  end

  @doc "Removes all entries from the cache."
  @spec flush() :: :ok
  def flush, do: GenServer.cast(__MODULE__, :flush)

  @doc "Returns the number of non-expired entries currently in the cache."
  @spec size() :: non_neg_integer()
  def size do
    now = System.monotonic_time(:millisecond)
    :ets.tab2list(@table) |> Enum.count(fn {_id, _perms, exp} -> exp > now end)
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @default_ttl_ms)
    Process.send_after(self(), :sweep, sweep_interval)
    {:ok, %{sweep_interval: sweep_interval}}
  end

  @impl GenServer
  def handle_cast({:put, user_id, permissions, ttl}, state) do
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table, {user_id, permissions, expires_at})
    {:noreply, state}
  end

  def handle_cast({:invalidate, user_id}, state) do
    :ets.delete(@table, user_id)
    {:noreply, state}
  end

  def handle_cast(:flush, state) do
    :ets.delete_all_objects(@table)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep_interval: interval} = state) do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.each(fn {user_id, _perms, expires_at} ->
      if expires_at <= now, do: :ets.delete(@table, user_id)
    end)

    Process.send_after(self(), :sweep, interval)
    {:noreply, state}
  end
end
```
