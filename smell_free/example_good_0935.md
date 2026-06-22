```elixir
defmodule Platform.ClusterBroadcast do
  @moduledoc """
  A GenServer that reliably delivers messages to every node currently
  in the BEAM cluster.

  Unlike `Phoenix.PubSub`, which relies on subscribers opting in,
  this module actively pushes messages to a named process on every
  known node. It is suitable for cluster-wide cache invalidation,
  config refresh notifications, and emergency shutdown signals.
  """

  use GenServer

  require Logger

  @type message :: term()
  @type delivery_result :: %{
          sent_to: [node()],
          failed: [node()],
          local: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Broadcasts `message` to `handler_name` on every connected cluster node,
  including the local node. Returns a delivery summary.
  """
  @spec broadcast(atom(), message()) :: delivery_result()
  def broadcast(handler_name, message) when is_atom(handler_name) do
    GenServer.call(__MODULE__, {:broadcast, handler_name, message})
  end

  @doc """
  Broadcasts `message` to all nodes, excluding the local node.
  Useful when the caller has already handled the message locally.
  """
  @spec broadcast_remote(atom(), message()) :: delivery_result()
  def broadcast_remote(handler_name, message) when is_atom(handler_name) do
    GenServer.call(__MODULE__, {:broadcast_remote, handler_name, message})
  end

  @doc """
  Sends `message` to `handler_name` on a specific `target_node`.
  Returns `:ok` or `{:error, :no_such_process}`.
  """
  @spec send_to_node(node(), atom(), message()) :: :ok | {:error, :no_such_process}
  def send_to_node(target_node, handler_name, message) do
    case :rpc.call(target_node, Process, :whereis, [handler_name], 5_000) do
      nil ->
        {:error, :no_such_process}

      {:badrpc, _} ->
        {:error, :no_such_process}

      pid when is_pid(pid) ->
        send(pid, {:cluster_broadcast, message})
        :ok
    end
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:broadcast, handler_name, message}, _from, state) do
    all_nodes = [node() | Node.list(:connected)]
    result = deliver_to_nodes(all_nodes, handler_name, message, include_local: true)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:broadcast_remote, handler_name, message}, _from, state) do
    remote_nodes = Node.list(:connected)
    result = deliver_to_nodes(remote_nodes, handler_name, message, include_local: false)
    {:reply, result, state}
  end

  defp deliver_to_nodes(nodes, handler_name, message, opts) do
    include_local = Keyword.get(opts, :include_local, true)

    {sent, failed} =
      nodes
      |> Enum.reject(fn n -> not include_local and n == node() end)
      |> Enum.split_with(fn target_node ->
        case deliver_one(target_node, handler_name, message) do
          :ok -> true
          {:error, reason} ->
            Logger.warning("[ClusterBroadcast] Delivery failed",
              node: target_node,
              handler: handler_name,
              reason: inspect(reason)
            )
            false
        end
      end)

    %{sent_to: sent, failed: failed, local: node() in sent}
  end

  defp deliver_one(local, handler_name, message) when local == node() do
    case Process.whereis(handler_name) do
      nil -> {:error, :no_such_process}
      pid -> send(pid, {:cluster_broadcast, message}); :ok
    end
  end

  defp deliver_one(target_node, handler_name, message) do
    case :rpc.call(target_node, Process, :whereis, [handler_name], 5_000) do
      nil -> {:error, :no_such_process}
      {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
      pid when is_pid(pid) ->
        :rpc.cast(target_node, Process, :send, [pid, {:cluster_broadcast, message}])
        :ok
    end
  end
end
```
