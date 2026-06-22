```elixir
defmodule Platform.LeaderElection do
  @moduledoc """
  A GenServer that participates in a cluster-wide leader election using
  Erlang's `:global` registry for distributed process naming.

  Each node races to register a well-known global name. The node that
  wins the race becomes the leader. Other nodes monitor the leader and
  re-elect when it crashes or disconnects. Callers receive `{:leader_changed, node}`
  notifications via PubSub.
  """

  use GenServer

  require Logger

  @type role :: :leader | :follower
  @type state :: %{role: role(), leader_node: node() | nil, monitor_ref: reference() | nil}

  @election_retry_ms 2_000
  @global_name :platform_leader

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns `:leader` or `:follower` for the current node."
  @spec role() :: role()
  def role, do: GenServer.call(__MODULE__, :role)

  @doc "Returns `true` if the current node is the cluster leader."
  @spec leader?() :: boolean()
  def leader?, do: GenServer.call(__MODULE__, :role) == :leader

  @doc "Returns the node currently acting as leader, or `nil` if unknown."
  @spec leader_node() :: node() | nil
  def leader_node, do: GenServer.call(__MODULE__, :leader_node)

  @impl GenServer
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, Platform.PubSub)
    send(self(), :elect)
    {:ok, %{role: :follower, leader_node: nil, monitor_ref: nil, pubsub: pubsub}}
  end

  @impl GenServer
  def handle_call(:role, _from, state), do: {:reply, state.role, state}
  def handle_call(:leader_node, _from, state), do: {:reply, state.leader_node, state}

  @impl GenServer
  def handle_info(:elect, state) do
    case :global.register_name(@global_name, self()) do
      :yes ->
        Logger.info("[LeaderElection] This node is now the leader", node: node())
        new_state = %{state | role: :leader, leader_node: node(), monitor_ref: nil}
        broadcast_change(state.pubsub, node())
        {:noreply, new_state}

      :no ->
        {:noreply, follow_existing_leader(state)}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    Logger.warning("[LeaderElection] Leader went down, re-electing", previous_leader: state.leader_node)
    :global.unregister_name(@global_name)
    Process.send_after(self(), :elect, jitter(@election_retry_ms))
    {:noreply, %{state | role: :follower, leader_node: nil, monitor_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp follow_existing_leader(state) do
    case :global.whereis_name(@global_name) do
      :undefined ->
        Process.send_after(self(), :elect, jitter(@election_retry_ms))
        state

      leader_pid ->
        leader = node(leader_pid)
        ref = Process.monitor(leader_pid)
        Logger.info("[LeaderElection] Following leader", leader: leader)
        broadcast_change(state.pubsub, leader)
        %{state | role: :follower, leader_node: leader, monitor_ref: ref}
    end
  end

  defp broadcast_change(pubsub, leader_node) do
    Phoenix.PubSub.broadcast(pubsub, "leader_election", {:leader_changed, leader_node})
  end

  defp jitter(base_ms) do
    base_ms + :rand.uniform(div(base_ms, 2))
  end
end
```
