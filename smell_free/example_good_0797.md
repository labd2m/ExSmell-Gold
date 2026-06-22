```elixir
defmodule MyApp.Realtime.ConnectionTracker do
  @moduledoc """
  Tracks the number of active WebSocket connections per tenant and per
  user using ETS for lock-free reads. A GenServer serialises increment
  and decrement writes, while any process can read current counts
  directly from ETS without a round-trip through the server. Stale
  entries from crashed socket processes are cleaned up via process
  monitoring.
  """

  use GenServer

  @table __MODULE__

  @type tenant_id :: String.t()
  @type user_id :: String.t()
  @type conn_key :: {:tenant, tenant_id()} | {:user, user_id()}

  @doc "Starts the connection tracker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a new connection for `tenant_id` and `user_id`. The calling
  process is monitored; when it exits the connection is automatically
  removed.
  """
  @spec connect(tenant_id(), user_id()) :: :ok
  def connect(tenant_id, user_id)
      when is_binary(tenant_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:connect, self(), tenant_id, user_id})
  end

  @doc "Manually records a disconnection, bypassing monitor cleanup."
  @spec disconnect(tenant_id(), user_id()) :: :ok
  def disconnect(tenant_id, user_id)
      when is_binary(tenant_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:disconnect, tenant_id, user_id})
  end

  @doc "Returns the current connection count for `tenant_id`."
  @spec tenant_count(tenant_id()) :: non_neg_integer()
  def tenant_count(tenant_id) when is_binary(tenant_id) do
    read_counter({:tenant, tenant_id})
  end

  @doc "Returns the current connection count for `user_id`."
  @spec user_count(user_id()) :: non_neg_integer()
  def user_count(user_id) when is_binary(user_id) do
    read_counter({:user, user_id})
  end

  @doc "Returns all tenants with at least one active connection."
  @spec active_tenants() :: [tenant_id()]
  def active_tenants do
    @table
    |> :ets.match({{:tenant, :"$1"}, :"$2"})
    |> Enum.filter(fn [_id, count] -> count > 0 end)
    |> Enum.map(fn [id, _count] -> id end)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl GenServer
  def handle_cast({:connect, pid, tenant_id, user_id}, state) do
    ref = Process.monitor(pid)
    increment({:tenant, tenant_id})
    increment({:user, user_id})
    monitors = Map.put(state.monitors, ref, {tenant_id, user_id})
    {:noreply, %{state | monitors: monitors}}
  end

  @impl GenServer
  def handle_cast({:disconnect, tenant_id, user_id}, state) do
    decrement({:tenant, tenant_id})
    decrement({:user, user_id})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{tenant_id, user_id}, monitors} ->
        decrement({:tenant, tenant_id})
        decrement({:user, user_id})
        {:noreply, %{state | monitors: monitors}}
    end
  end

  @spec increment(conn_key()) :: :ok
  defp increment(key) do
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  end

  @spec decrement(conn_key()) :: :ok
  defp decrement(key) do
    case :ets.lookup(@table, key) do
      [{^key, count}] when count > 1 ->
        :ets.update_counter(@table, key, {2, -1})

      _ ->
        :ets.delete(@table, key)
    end

    :ok
  end

  @spec read_counter(conn_key()) :: non_neg_integer()
  defp read_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end
end
```
