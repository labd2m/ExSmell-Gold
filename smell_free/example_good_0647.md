```elixir
defmodule Cluster.MembershipTracker do
  @moduledoc """
  Tracks cluster membership changes by subscribing to `:net_kernel` node
  up/down events. Maintains a local view of which nodes are alive and what
  roles they have declared, broadcasting changes to interested processes
  via Phoenix PubSub. The tracker is the single source of truth for cluster
  topology inside the application, replacing ad-hoc `Node.list()` calls
  scattered through the codebase.
  """

  use GenServer

  require Logger

  @pubsub_topic "cluster:membership"
  @discovery_interval_ms 30_000

  @type node_name :: atom()
  @type node_role :: :primary | :worker | :scheduler
  @type member :: %{node: node_name(), role: node_role(), joined_at: DateTime.t()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current known cluster members excluding the local node.
  """
  @spec members() :: [member()]
  def members do
    GenServer.call(__MODULE__, :members)
  end

  @doc """
  Returns `true` when `node` is currently a known cluster member.
  """
  @spec member?(node_name()) :: boolean()
  def member?(node) when is_atom(node) do
    GenServer.call(__MODULE__, {:member?, node})
  end

  @doc """
  Returns only members that have declared the given `role`.
  """
  @spec members_by_role(node_role()) :: [member()]
  def members_by_role(role) when is_atom(role) do
    members() |> Enum.filter(&(&1.role == role))
  end

  @doc """
  Declares this node's role to all connected peers. Each peer's tracker
  will update its member entry accordingly.
  """
  @spec announce_role(node_role()) :: :ok
  def announce_role(role) when is_atom(role) do
    GenServer.cast(__MODULE__, {:announce_role, role})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    :net_kernel.monitor_nodes(true, node_type: :all)
    local_role = Keyword.get(opts, :role, :worker)
    schedule_discovery()

    state = %{
      members: %{},
      local_role: local_role
    }

    {:ok, state, {:continue, :initial_discovery}}
  end

  @impl GenServer
  def handle_continue(:initial_discovery, state) do
    discovered =
      Node.list()
      |> Enum.reduce(state.members, fn node, acc ->
        role = fetch_remote_role(node)
        Map.put(acc, node, build_member(node, role))
      end)

    {:noreply, %{state | members: discovered}}
  end

  @impl GenServer
  def handle_call(:members, _from, state) do
    {:reply, Map.values(state.members), state}
  end

  def handle_call({:member?, node}, _from, state) do
    {:reply, Map.has_key?(state.members, node), state}
  end

  @impl GenServer
  def handle_cast({:announce_role, role}, state) do
    :rpc.abcast(Node.list(), __MODULE__, {:peer_role, Node.self(), role})
    {:noreply, %{state | local_role: role}}
  end

  @impl GenServer
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node joined cluster", node: node)
    role = fetch_remote_role(node)
    member = build_member(node, role)
    new_members = Map.put(state.members, node, member)
    broadcast({:node_joined, member})
    {:noreply, %{state | members: new_members}}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("Node left cluster", node: node)
    member = Map.get(state.members, node)
    new_members = Map.delete(state.members, node)
    if member, do: broadcast({:node_left, member})
    {:noreply, %{state | members: new_members}}
  end

  def handle_info({:peer_role, node, role}, state) do
    new_members =
      Map.update(state.members, node, build_member(node, role), fn m -> %{m | role: role} end)

    {:noreply, %{state | members: new_members}}
  end

  def handle_info(:rediscover, state) do
    handle_continue(:initial_discovery, state)
    schedule_discovery()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_member(node, role) do
    %{node: node, role: role, joined_at: DateTime.utc_now()}
  end

  defp fetch_remote_role(node) do
    case :rpc.call(node, GenServer, :call, [__MODULE__, :local_role], 3_000) do
      {:badrpc, _} -> :worker
      role when is_atom(role) -> role
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic, message)
  end

  defp schedule_discovery do
    Process.send_after(self(), :rediscover, @discovery_interval_ms)
  end
end
```
