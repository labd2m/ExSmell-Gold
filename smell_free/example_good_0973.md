```elixir
defmodule MyApp.Catalogue.CategoryTree do
  @moduledoc """
  Builds and traverses an in-memory category tree from a flat list of
  `Category` records. The tree supports breadcrumb generation, subtree
  extraction, and flattening to leaf nodes — all without additional
  database queries once the tree is built.

  Trees are reconstructed from a fresh database load each time
  `build/0` is called; callers can cache the result for the duration
  of a request.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Catalogue.Category

  @type category_id :: String.t()

  @type tree_node :: %{
          category: Category.t(),
          children: [tree_node()]
        }

  @doc "Fetches all categories and returns the fully-built tree of root nodes."
  @spec build() :: [tree_node()]
  def build do
    Category
    |> order_by([c], asc: c.position, asc: c.name)
    |> Repo.all()
    |> build_from_list()
  end

  @doc "Builds a tree from a pre-fetched flat list of categories."
  @spec build_from_list([Category.t()]) :: [tree_node()]
  def build_from_list(categories) when is_list(categories) do
    nodes = Map.new(categories, fn c -> {c.id, %{category: c, children: []}} end)

    {roots, tree} =
      Enum.reduce(categories, {[], nodes}, fn cat, {roots, tree} ->
        if is_nil(cat.parent_id) do
          {[cat.id | roots], tree}
        else
          updated = Map.update(tree, cat.parent_id, %{category: nil, children: [cat.id]}, fn parent ->
            %{parent | children: parent.children ++ [cat.id]}
          end)

          {roots, updated}
        end
      end)

    resolve_nodes(Enum.reverse(roots), tree)
  end

  @doc """
  Returns the breadcrumb path from the root to `category_id` as an
  ordered list of categories.
  """
  @spec breadcrumbs([Category.t()], category_id()) :: [Category.t()]
  def breadcrumbs(categories, category_id) when is_binary(category_id) do
    by_id = Map.new(categories, &{&1.id, &1})
    build_breadcrumbs(category_id, by_id, [])
  end

  @doc "Returns all leaf categories (those with no children) from `tree`."
  @spec leaves([tree_node()]) :: [Category.t()]
  def leaves(tree) when is_list(tree) do
    Enum.flat_map(tree, &collect_leaves/1)
  end

  @doc """
  Returns the subtree rooted at `category_id`, or `nil` when not found.
  """
  @spec subtree([tree_node()], category_id()) :: tree_node() | nil
  def subtree(tree, category_id) when is_list(tree) and is_binary(category_id) do
    Enum.find_value(tree, fn node ->
      if node.category.id == category_id do
        node
      else
        subtree(node.children, category_id)
      end
    end)
  end

  @spec resolve_nodes([category_id()], %{category_id() => map()}) :: [tree_node()]
  defp resolve_nodes(ids, node_map) do
    Enum.flat_map(ids, fn id ->
      case Map.get(node_map, id) do
        nil -> []
        node ->
          resolved_children = resolve_nodes(node.children, node_map)
          [%{category: node.category, children: resolved_children}]
      end
    end)
  end

  @spec build_breadcrumbs(category_id(), %{category_id() => Category.t()}, [Category.t()]) ::
          [Category.t()]
  defp build_breadcrumbs(nil, _by_id, acc), do: acc

  defp build_breadcrumbs(id, by_id, acc) do
    case Map.get(by_id, id) do
      nil -> acc
      cat -> build_breadcrumbs(cat.parent_id, by_id, [cat | acc])
    end
  end

  @spec collect_leaves(tree_node()) :: [Category.t()]
  defp collect_leaves(%{children: [], category: cat}), do: [cat]
  defp collect_leaves(%{children: children}), do: Enum.flat_map(children, &collect_leaves/1)
end
```
