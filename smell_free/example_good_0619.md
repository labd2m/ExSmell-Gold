# File: `example_good_619.md`

```elixir
defmodule Cluster.ElectionCoordinator do
  @moduledoc """
  GenServer implementing a simple bully-algorithm leader election for
  a cluster of named Elixir nodes.

  Each coordinator monitors peer nodes via `Node.monitor`. When the
  current leader becomes unreachable, a new election is triggered and
  the node with the highest alphabetical name wins. The result is
  broadcast via Phoenix.PubSub so subscribers can react to leadership
  changes without polling.
  """

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @pubsub MyApp.PubSub
  @election_topic "cluster:election"
  @election_timeout_ms 3_000

  @type node_name :: node()

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `true` when this node is the current cluster leader.
  """
  @spec leader?() :: boolean()
  def leader? do
    GenServer.call(__MODULE__, :leader?)
  end

  @doc """
  Returns the current leader node name, or `nil` if no leader is elected.
  """
  @spec current_leader() :: node_name() | nil
  def current_leader do
    GenServer.call(__MODULE__, :current_leader)
  end

  @doc """
  Triggers a new election round, useful after adding nodes to the cluster.
  """
  @spec trigger_election() :: :ok
  def trigger_election do
    GenServer.cast(__MODULE__, :trigger_election)
  end

  @impl GenServer
  def init(opts) do
    peers = Keyword.get(opts, :peers, [])
    Enum.each(peers, &Node.monitor(&1, true))
    :net_kernel.monitor_nodes(true)

    state = %{leader: nil, peers: MapSet.new(peers), election_ref: nil}
    {:ok, state, {:continue, :initial_election}}
  end

  @impl GenServer
  def handle_continue(:initial_election, state) do
    {:noreply, start_election(state)}
  end

  @impl GenServer
  def handle_call(:leader?, _from, state) do
    {:reply, state.leader == node(), state}
  end

  @impl GenServer
  def handle_call(:current_leader, _from, state) do
    {:reply, state.leader, state}
  end

  @impl GenServer
  def handle_cast(:trigger_election, state) do
    {:noreply, start_election(state)}
  end

  @impl GenServer
  def handle_info({:nodeup, new_node}, state) do
    Logger.info("Node joined: #{new_node}")
    Node.monitor(new_node, true)
    new_peers = MapSet.put(state.peers, new_node)
    {:noreply, start_election(%{state | peers: new_peers})}
  end

  @impl GenServer
  def handle_info({:nodedown, down_node}, state) do
    Logger.warning("Node left: #{down_node}")
    new_peers = MapSet.delete(state.peers, down_node)
    new_state = %{state | peers: new_peers}

    if state.leader == down_node do
      Logger.info("Leader #{down_node} lost — starting election")
      {:noreply, start_election(%{new_state | leader: nil})}
    else
      {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:election_result, leader}, state) do
    if state.leader != leader do
      Logger.info("New leader elected: #{leader}")
      PubSub.broadcast(@pubsub, @election_topic, {:leader_changed, leader})
    end

    {:noreply, %{state | leader: leader, election_ref: nil}}
  end

  @impl GenServer
  def handle_info({:election_timeout, ref}, %{election_ref: ref} = state) do
    winner = elect_winner(state.peers)
    Logger.info("Election concluded, winner: #{winner}")
    send(self(), {:election_result, winner})
    {:noreply, %{state | election_ref: nil}}
  end

  @impl GenServer
  def handle_info({:election_timeout, _stale_ref}, state) do
    {:noreply, state}
  end

  defp start_election(state) do
    if state.election_ref, do: Process.cancel_timer(state.election_ref)

    ref = Process.send_after(self(), {:election_timeout, make_ref()}, @election_timeout_ms)
    broadcast_candidacy(state.peers)
    %{state | election_ref: ref}
  end

  defp broadcast_candidacy(peers) do
    Enum.each(peers, fn peer ->
      :rpc.cast(peer, __MODULE__, :notify_candidacy, [node()])
    end)
  end

  @doc false
  def notify_candidacy(candidate) do
    GenServer.cast(__MODULE__, {:candidacy, candidate})
  end

  defp elect_winner(peers) do
    all_nodes = [node() | MapSet.to_list(peers)]

    all_nodes
    |> Enum.filter(&Node.alive?/1)
    |> Enum.sort(:desc)
    |> List.first()
    |> Kernel.||(node())
  end
end
```
