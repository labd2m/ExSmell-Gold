# File: `example_good_818.md`

```elixir
defmodule Cluster.GossipProtocol do
  @moduledoc """
  GenServer implementing a gossip protocol for propagating lightweight
  node metadata (e.g. load, version, capabilities) across a cluster.

  On each gossip round this node selects a random peer and exchanges
  its current state vector. Received updates are merged using a
  last-write-wins strategy keyed on vector timestamps.

  This implementation intentionally keeps the gossip payload small;
  only scalar metadata values are gossiped, not full state.
  """

  use GenServer

  require Logger

  @default_gossip_interval_ms 2_000
  @default_fanout 2

  @type node_name :: node()
  @type metadata_key :: atom()
  @type vector_entry :: %{value: term(), timestamp: integer()}
  @type state_vector :: %{node_name() => %{metadata_key() => vector_entry()}}

  @type opts :: [
          gossip_interval_ms: pos_integer(),
          fanout: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sets a local metadata key-value pair to be gossiped to peers.
  """
  @spec set_local(metadata_key(), term()) :: :ok
  def set_local(key, value) when is_atom(key) do
    GenServer.cast(__MODULE__, {:set_local, key, value})
  end

  @doc """
  Returns the full merged state vector, keyed by node name.
  """
  @spec state_vector() :: state_vector()
  def state_vector do
    GenServer.call(__MODULE__, :state_vector)
  end

  @doc """
  Returns the most recently gossiped value for a key on a specific node.
  """
  @spec get(node_name(), metadata_key()) :: {:ok, term()} | {:error, :not_found}
  def get(node_name, key) when is_atom(key) do
    GenServer.call(__MODULE__, {:get, node_name, key})
  end

  @doc """
  Returns a flat map of `node => %{key => value}` for easy consumption.
  """
  @spec snapshot() :: %{node_name() => %{metadata_key() => term()}}
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc false
  def receive_gossip(from_node, remote_vector) when is_map(remote_vector) do
    GenServer.cast(__MODULE__, {:receive_gossip, from_node, remote_vector})
  end

  @impl GenServer
  def init(opts) do
    gossip_interval_ms = Keyword.get(opts, :gossip_interval_ms, @default_gossip_interval_ms)
    fanout = Keyword.get(opts, :fanout, @default_fanout)

    :net_kernel.monitor_nodes(true)
    schedule_gossip(gossip_interval_ms)

    {:ok, %{vector: %{node() => %{}}, gossip_interval_ms: gossip_interval_ms, fanout: fanout}}
  end

  @impl GenServer
  def handle_cast({:set_local, key, value}, state) do
    entry = %{value: value, timestamp: System.monotonic_time(:millisecond)}
    new_vector = put_in(state.vector, [node(), key], entry)
    {:noreply, %{state | vector: new_vector}}
  end

  @impl GenServer
  def handle_cast({:receive_gossip, _from_node, remote_vector}, state) do
    merged = merge_vectors(state.vector, remote_vector)
    {:noreply, %{state | vector: merged}}
  end

  @impl GenServer
  def handle_call(:state_vector, _from, state) do
    {:reply, state.vector, state}
  end

  @impl GenServer
  def handle_call({:get, node_name, key}, _from, state) do
    result =
      case get_in(state.vector, [node_name, key]) do
        nil -> {:error, :not_found}
        %{value: value} -> {:ok, value}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    flat =
      Map.new(state.vector, fn {node_name, entries} ->
        {node_name, Map.new(entries, fn {key, %{value: val}} -> {key, val} end)}
      end)

    {:reply, flat, state}
  end

  @impl GenServer
  def handle_info(:gossip, state) do
    send_gossip(state)
    schedule_gossip(state.gossip_interval_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}
  def handle_info({:nodedown, node}, state) do
    {:noreply, update_in(state, [:vector], &Map.delete(&1, node))}
  end

  defp send_gossip(state) do
    peers = Node.list()

    peers
    |> Enum.shuffle()
    |> Enum.take(state.fanout)
    |> Enum.each(fn peer ->
      :rpc.cast(peer, __MODULE__, :receive_gossip, [node(), state.vector])
    end)
  end

  defp merge_vectors(local, remote) do
    Map.merge(local, remote, fn _node, local_entries, remote_entries ->
      Map.merge(local_entries, remote_entries, fn _key, local_entry, remote_entry ->
        if remote_entry.timestamp > local_entry.timestamp, do: remote_entry, else: local_entry
      end)
    end)
  end

  defp schedule_gossip(interval_ms) do
    Process.send_after(self(), :gossip, interval_ms)
  end
end
```
