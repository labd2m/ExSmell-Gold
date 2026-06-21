```elixir
defmodule Catalog.CategoryTree do
  @moduledoc """
  Builds and queries a nested category tree for product navigation.
  Categories are stored flat in the database with a `parent_id` reference.
  This module assembles them into a recursive tree structure in memory for
  rendering navigation menus and computing category ancestors. All
  functions operate on pre-fetched lists to avoid N+1 queries.
  """

  @enforce_keys [:id, :name, :slug, :parent_id]
  defstruct [:id, :name, :slug, :parent_id, children: []]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          slug: String.t(),
          parent_id: String.t() | nil,
          children: [t()]
        }

  @doc "Assembles a flat list of category maps into a nested tree."
  @spec build([map()]) :: [t()]
  def build(flat_categories) when is_list(flat_categories) do
    nodes = Map.new(flat_categories, fn cat ->
      node = %__MODULE__{
        id: cat.id, name: cat.name, slug: cat.slug, parent_id: cat.parent_id
      }
      {cat.id, node}
    end)

    nodes
    |> Map.values()
    |> Enum.filter(fn node -> is_nil(node.parent_id) end)
    |> Enum.map(fn root -> attach_children(root, nodes) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Finds a node by slug within a tree."
  @spec find_by_slug([t()], String.t()) :: {:ok, t()} | {:error, :not_found}
  def find_by_slug(tree, slug) when is_list(tree) and is_binary(slug) do
    case find_node(tree, fn n -> n.slug == slug end) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  @doc "Returns the ancestor chain from the root down to the node with `id`."
  @spec ancestors([t()], String.t()) :: [t()]
  def ancestors(tree, target_id) when is_list(tree) and is_binary(target_id) do
    collect_ancestors(tree, target_id, []) || []
  end

  @doc "Returns all descendants of the node with `id` as a flat list."
  @spec descendants([t()], String.t()) :: [t()]
  def descendants(tree, target_id) when is_list(tree) and is_binary(target_id) do
    case find_node(tree, fn n -> n.id == target_id end) do
      nil -> []
      node -> flatten_children(node.children)
    end
  end

  @doc "Returns the maximum depth of the tree."
  @spec max_depth([t()]) :: non_neg_integer()
  def max_depth([]), do: 0
  def max_depth(nodes) when is_list(nodes) do
    Enum.map(nodes, fn node ->
      if Enum.empty?(node.children), do: 1, else: 1 + max_depth(node.children)
    end)
    |> Enum.max()
  end

  defp attach_children(node, nodes) do
    children =
      nodes
      |> Map.values()
      |> Enum.filter(fn n -> n.parent_id == node.id end)
      |> Enum.map(fn child -> attach_children(child, nodes) end)
      |> Enum.sort_by(& &1.name)

    %{node | children: children}
  end

  defp find_node([], _pred), do: nil

  defp find_node([node | rest], pred) do
    if pred.(node) do
      node
    else
      find_node(node.children, pred) || find_node(rest, pred)
    end
  end

  defp collect_ancestors([], _target_id, _path), do: nil

  defp collect_ancestors([node | rest], target_id, path) do
    if node.id == target_id do
      Enum.reverse([node | path])
    else
      case collect_ancestors(node.children, target_id, [node | path]) do
        nil -> collect_ancestors(rest, target_id, path)
        result -> result
      end
    end
  end

  defp flatten_children([]), do: []
  defp flatten_children(children) do
    Enum.flat_map(children, fn child -> [child | flatten_children(child.children)] end)
  end
end
```
