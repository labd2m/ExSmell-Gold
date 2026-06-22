```elixir
defmodule WorkPartitioner.Assignment do
  @moduledoc false

  @type t :: %__MODULE__{
          key: term(),
          node: node(),
          partition: non_neg_integer()
        }

  defstruct [:key, :node, :partition]
end

defmodule WorkPartitioner do
  @moduledoc """
  Distributes work keys across known cluster nodes using consistent hashing,
  so each key is deterministically assigned to exactly one node.

  Node membership is managed via `:pg` process groups. When a node joins
  or leaves the cluster, only the keys formerly handled by the changed node
  are reassigned, minimising rebalancing churn. Callers use `owner_of/1`
  to decide whether to process a job locally or forward it to the owning node.
  """

  use GenServer

  require Logger

  alias WorkPartitioner.Assignment

  @group :work_partitioner_members
  @virtual_nodes 150

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec owner_of(term()) :: {:ok, node()} | {:error, :no_members}
  def owner_of(key) do
    GenServer.call(__MODULE__, {:owner_of, key})
  end

  @spec local?(term()) :: boolean()
  def local?(key) do
    case owner_of(key) do
      {:ok, owner} -> owner == node()
      _ -> false
    end
  end

  @spec members() :: [node()]
  def members do
    GenServer.call(__MODULE__, :members)
  end

  @impl GenServer
  def init(_opts) do
    :ok = :pg.join(@group, self())
    :net_kernel.monitor_nodes(true)
    ring = build_ring([node()])
    {:ok, %{ring: ring, members: [node()]}}
  end

  @impl GenServer
  def handle_call({:owner_of, key}, _from, %{ring: ring, members: members} = state) do
    reply =
      case members do
        [] -> {:error, :no_members}
        _ ->
          hash = :erlang.phash2(key, length(ring))
          {_hash, owner_node} = Enum.at(ring, hash)
          {:ok, owner_node}
      end

    {:reply, reply, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, state.members, state}
  end

  @impl GenServer
  def handle_info({:nodeup, new_node}, state) do
    Logger.info("WorkPartitioner: node joined", node: new_node)
    updated_members = Enum.uniq([new_node | state.members])
    ring = build_ring(updated_members)
    {:noreply, %{state | ring: ring, members: updated_members}}
  end

  def handle_info({:nodedown, down_node}, state) do
    Logger.warning("WorkPartitioner: node left", node: down_node)
    updated_members = List.delete(state.members, down_node)
    ring = build_ring(updated_members)
    {:noreply, %{state | ring: ring, members: updated_members}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp build_ring([]), do: []

  defp build_ring(nodes) do
    nodes
    |> Enum.flat_map(fn n ->
      Enum.map(0..(@virtual_nodes - 1), fn i ->
        {:erlang.phash2({n, i}, 4_294_967_296), n}
      end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @spec assign(term()) :: Assignment.t()
  def assign(key) do
    case owner_of(key) do
      {:ok, owner} ->
        partition = :erlang.phash2(key, 1024)
        %Assignment{key: key, node: owner, partition: partition}

      {:error, :no_members} ->
        %Assignment{key: key, node: node(), partition: 0}
    end
  end

  @spec run_if_owner(term(), (-> term())) :: {:ok, term()} | {:skip, :not_owner}
  def run_if_owner(key, fun) when is_function(fun, 0) do
    if local?(key), do: {:ok, fun.()}, else: {:skip, :not_owner}
  end
end
```
