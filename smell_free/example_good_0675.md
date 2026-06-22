```elixir
defmodule Org.Node do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          parent_id: String.t() | nil,
          metadata: map()
        }

  defstruct [:id, :name, :parent_id, metadata: %{}]
end

defmodule Org.Hierarchy do
  @moduledoc """
  Operates on a flat list of organisational nodes to answer tree queries
  without requiring a recursive SQL CTE or a nested structure in memory.

  Nodes are indexed by ID on first use via a private helper. All operations
  are pure functions; the caller owns the list and can refresh it on demand
  without invalidating any cached state inside this module.
  """

  alias Org.Node

  @type node_list :: [Node.t()]

  @spec ancestors(node_list(), String.t()) :: [Node.t()]
  def ancestors(nodes, id) when is_list(nodes) and is_binary(id) do
    index = index_by_id(nodes)
    collect_ancestors(index, id, [])
  end

  @spec descendants(node_list(), String.t()) :: [Node.t()]
  def descendants(nodes, id) when is_list(nodes) and is_binary(id) do
    collect_descendants(nodes, id, [])
  end

  @spec path(node_list(), String.t()) :: [Node.t()]
  def path(nodes, id) when is_list(nodes) and is_binary(id) do
    index = index_by_id(nodes)

    case Map.fetch(index, id) do
      :error -> []
      {:ok, node} -> Enum.reverse([node | collect_ancestors(index, id, [])])
    end
  end

  @spec depth(node_list(), String.t()) :: non_neg_integer()
  def depth(nodes, id) when is_list(nodes) and is_binary(id) do
    length(ancestors(nodes, id))
  end

  @spec children(node_list(), String.t()) :: [Node.t()]
  def children(nodes, parent_id) when is_list(nodes) and is_binary(parent_id) do
    Enum.filter(nodes, &(&1.parent_id == parent_id))
  end

  @spec roots(node_list()) :: [Node.t()]
  def roots(nodes) when is_list(nodes) do
    Enum.filter(nodes, &is_nil(&1.parent_id))
  end

  @spec subtree(node_list(), String.t()) :: node_list()
  def subtree(nodes, id) when is_list(nodes) and is_binary(id) do
    index = index_by_id(nodes)

    case Map.fetch(index, id) do
      :error -> []
      {:ok, root} -> [root | collect_descendants(nodes, id, [])]
    end
  end

  @spec move(node_list(), String.t(), String.t() | nil) ::
          {:ok, node_list()} | {:error, :not_found | :would_create_cycle}
  def move(nodes, id, new_parent_id) do
    index = index_by_id(nodes)

    with {:ok, _node} <- Map.fetch(index, id),
         :ok <- validate_no_cycle(nodes, id, new_parent_id) do
      updated = Enum.map(nodes, fn n ->
        if n.id == id, do: %{n | parent_id: new_parent_id}, else: n
      end)
      {:ok, updated}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec leaf?(node_list(), String.t()) :: boolean()
  def leaf?(nodes, id) when is_list(nodes) and is_binary(id) do
    Enum.all?(nodes, &(&1.parent_id != id))
  end

  defp collect_ancestors(_index, nil, acc), do: acc
  defp collect_ancestors(index, id, acc) do
    case Map.fetch(index, id) do
      {:ok, %Node{parent_id: nil}} -> acc
      {:ok, %Node{parent_id: parent_id}} ->
        parent = Map.fetch!(index, parent_id)
        collect_ancestors(index, parent_id, [parent | acc])
      :error -> acc
    end
  end

  defp collect_descendants(nodes, id, acc) do
    direct = Enum.filter(nodes, &(&1.parent_id == id))
    Enum.reduce(direct, acc ++ direct, fn child, inner_acc ->
      collect_descendants(nodes, child.id, inner_acc)
    end)
  end

  defp validate_no_cycle(_nodes, _id, nil), do: :ok
  defp validate_no_cycle(nodes, id, new_parent_id) do
    descendant_ids = nodes |> descendants(id) |> Enum.map(& &1.id) |> MapSet.new()
    if new_parent_id == id or MapSet.member?(descendant_ids, new_parent_id) do
      {:error, :would_create_cycle}
    else
      :ok
    end
  end

  defp index_by_id(nodes), do: Map.new(nodes, &{&1.id, &1})
end
```
