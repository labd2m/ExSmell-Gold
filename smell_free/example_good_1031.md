```elixir
defmodule Platform.MaintenanceModeServer do
  @moduledoc """
  Controls a cluster-wide maintenance mode flag. When maintenance mode is
  active the `MaintenanceWindow` plug serves 503 responses. The flag is
  toggled via this GenServer so changes take effect on all cluster nodes
  via Phoenix PubSub without requiring a process restart. Activation and
  deactivation are both logged with the operator identity.
  """

  use GenServer

  require Logger

  @pubsub_topic "ops:maintenance"
  @table :maintenance_mode_state

  @type operator :: String.t()
  @type state_snapshot :: %{active: boolean(), activated_by: operator() | nil, activated_at: DateTime.t() | nil}

  @doc "Starts the maintenance mode server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Activates maintenance mode on behalf of `operator`."
  @spec activate(operator()) :: :ok
  def activate(operator) when is_binary(operator) do
    GenServer.call(__MODULE__, {:activate, operator})
  end

  @doc "Deactivates maintenance mode on behalf of `operator`."
  @spec deactivate(operator()) :: :ok
  def deactivate(operator) when is_binary(operator) do
    GenServer.call(__MODULE__, {:deactivate, operator})
  end

  @doc "Returns true when maintenance mode is currently active on this node."
  @spec active?() :: boolean()
  def active? do
    case :ets.lookup(@table, :state) do
      [{:state, %{active: active}}] -> active
      [] -> false
    end
  end

  @doc "Returns the current maintenance state snapshot."
  @spec snapshot() :: state_snapshot()
  def snapshot do
    case :ets.lookup(@table, :state) do
      [{:state, snap}] -> snap
      [] -> %{active: false, activated_by: nil, activated_at: nil}
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(MyApp.PubSub, @pubsub_topic)
    :ets.insert(@table, {:state, %{active: false, activated_by: nil, activated_at: nil}})
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:activate, operator}, _from, state) do
    snap = %{active: true, activated_by: operator, activated_at: DateTime.utc_now()}
    :ets.insert(@table, {:state, snap})
    Logger.warning("[MaintenanceModeServer] Maintenance mode ACTIVATED by #{operator}")
    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic, {:maintenance_state_changed, snap})
    {:reply, :ok, state}
  end

  def handle_call({:deactivate, operator}, _from, state) do
    snap = %{active: false, activated_by: nil, activated_at: nil}
    :ets.insert(@table, {:state, snap})
    Logger.info("[MaintenanceModeServer] Maintenance mode DEACTIVATED by #{operator}")
    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic, {:maintenance_state_changed, snap})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:maintenance_state_changed, snap}, state) do
    :ets.insert(@table, {:state, snap})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```
