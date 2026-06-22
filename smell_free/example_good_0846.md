```elixir
defmodule Ops.ClusterHealthMonitor do
  @moduledoc """
  Monitors the health of Erlang cluster nodes from a single coordinator
  process. The monitor pings known nodes on a configurable interval and
  tracks their reachability status. Status changes are broadcast via
  PubSub and recorded in a structured history so operators can review
  node connectivity over time without external tooling.
  """

  use GenServer

  require Logger

  @type node_name :: atom()
  @type node_status :: :reachable | :unreachable
  @type node_record :: %{
          node: node_name(),
          status: node_status(),
          last_checked_at: DateTime.t(),
          consecutive_failures: non_neg_integer()
        }

  @default_interval_ms :timer.seconds(15)
  @failure_threshold 3
  @pubsub_topic "cluster:health"

  @doc "Starts the cluster health monitor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current health record for each tracked node."
  @spec node_records() :: [node_record()]
  def node_records, do: GenServer.call(__MODULE__, :node_records)

  @doc "Returns true when all tracked nodes are currently reachable."
  @spec all_reachable?() :: boolean()
  def all_reachable? do
    GenServer.call(__MODULE__, :all_reachable?)
  end

  @doc "Adds a node to the tracked set."
  @spec track(node_name()) :: :ok
  def track(node) when is_atom(node) do
    GenServer.cast(__MODULE__, {:track, node})
  end

  @doc "Removes a node from the tracked set."
  @spec untrack(node_name()) :: :ok
  def untrack(node) when is_atom(node) do
    GenServer.cast(__MODULE__, {:untrack, node})
  end

  @impl GenServer
  def init(opts) do
    nodes = Keyword.get(opts, :nodes, [])
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    records = Map.new(nodes, fn n ->
      {n, initial_record(n)}
    end)

    Process.send_after(self(), :check, interval)
    {:ok, %{records: records, interval: interval}}
  end

  @impl GenServer
  def handle_call(:node_records, _from, state) do
    {:reply, Map.values(state.records), state}
  end

  def handle_call(:all_reachable?, _from, state) do
    all = Enum.all?(Map.values(state.records), fn r -> r.status == :reachable end)
    {:reply, all, state}
  end

  @impl GenServer
  def handle_cast({:track, node}, state) do
    new_records = Map.put_new(state.records, node, initial_record(node))
    {:noreply, %{state | records: new_records}}
  end

  def handle_cast({:untrack, node}, state) do
    {:noreply, %{state | records: Map.delete(state.records, node)}}
  end

  @impl GenServer
  def handle_info(:check, %{interval: interval} = state) do
    new_records =
      Map.new(state.records, fn {node, record} ->
        {node, ping_and_update(node, record)}
      end)

    Process.send_after(self(), :check, interval)
    {:noreply, %{state | records: new_records}}
  end

  defp ping_and_update(node, record) do
    reachable = Node.ping(node) == :pong
    now = DateTime.utc_now()

    {new_status, failures} =
      if reachable do
        {:reachable, 0}
      else
        new_failures = record.consecutive_failures + 1
        status = if new_failures >= @failure_threshold, do: :unreachable, else: record.status
        {status, new_failures}
      end

    if new_status != record.status do
      broadcast_status_change(node, new_status)
      Logger.info("[ClusterHealthMonitor] #{node}: #{record.status} → #{new_status}")
    end

    %{record | status: new_status, last_checked_at: now, consecutive_failures: failures}
  end

  defp broadcast_status_change(node, status) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic, {:node_status_changed, node, status})
  end

  defp initial_record(node) do
    %{node: node, status: :reachable, last_checked_at: DateTime.utc_now(), consecutive_failures: 0}
  end
end
```
