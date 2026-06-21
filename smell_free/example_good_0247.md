# File: `example_good_247.md`

```elixir
defmodule Catalog.CategoryTree do
  @moduledoc """
  Builds and navigates a nested product category tree from a flat list
  of category records containing parent references.

  All operations are pure transformations over the tree structure.
  The tree is built once and can be cached by the caller; individual
  operations such as finding ancestors or building breadcrumbs are
  O(depth) once the tree is constructed.
  """

  @type category_id :: pos_integer()

  @type category :: %{
          required(:id) => category_id(),
          required(:name) => String.t(),
          required(:parent_id) => category_id() | nil,
          required(:slug) => String.t()
        }

  @type tree_node :: %{
          id: category_id(),
          name: String.t(),
          slug: String.t(),
          children: [tree_node()]
        }

  @doc """
  Assembles a flat list of categories into a nested tree.

  Categories with `parent_id: nil` become root nodes. Returns
  `{:ok, [tree_node()]}` with the list of root nodes, or
  `{:error, :cycle_detected}` if the parent references form a cycle.
  """
  @spec build([category()]) :: {:ok, [tree_node()]} | {:error, :cycle_detected}
  def build(categories) when is_list(categories) do
    by_parent = Enum.group_by(categories, & &1.parent_id)
    roots = Map.get(by_parent, nil, [])

    if cycle_present?(categories) do
      {:error, :cycle_detected}
    else
      tree = Enum.map(roots, &to_node(&1, by_parent))
      {:ok, tree}
    end
  end

  @doc """
  Returns the ancestor chain for a given category ID as a list from
  root to parent (not including the category itself).
  """
  @spec ancestors(category_id(), [category()]) :: [category()]
  def ancestors(category_id, categories) when is_list(categories) do
    by_id = Map.new(categories, &{&1.id, &1})
    collect_ancestors(category_id, by_id, [])
  end

  @doc """
  Returns a breadcrumb list from root to the category with `category_id`.
  Each element is a `%{name: string, slug: string}` map.
  """
  @spec breadcrumbs(category_id(), [category()]) :: [%{name: String.t(), slug: String.t()}]
  def breadcrumbs(category_id, categories) when is_list(categories) do
    by_id = Map.new(categories, &{&1.id, &1})

    case Map.fetch(by_id, category_id) do
      {:ok, current} ->
        ancestor_crumbs = collect_ancestors(category_id, by_id, []) |> Enum.map(&to_crumb/1)
        ancestor_crumbs ++ [to_crumb(current)]

      :error ->
        []
    end
  end

  @doc """
  Returns all descendant IDs of a given category, recursively.
  """
  @spec descendant_ids(category_id(), [category()]) :: [category_id()]
  def descendant_ids(category_id, categories) when is_list(categories) do
    by_parent = Enum.group_by(categories, & &1.parent_id)
    collect_descendants(category_id, by_parent, [])
  end

  @doc """
  Returns `true` if `candidate_id` is an ancestor of `category_id`.
  """
  @spec ancestor_of?(category_id(), category_id(), [category()]) :: boolean()
  def ancestor_of?(candidate_id, category_id, categories) do
    ancestor_ids = ancestors(category_id, categories) |> Enum.map(& &1.id)
    candidate_id in ancestor_ids
  end

  defp to_node(category, by_parent) do
    children =
      by_parent
      |> Map.get(category.id, [])
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&to_node(&1, by_parent))

    %{id: category.id, name: category.name, slug: category.slug, children: children}
  end

  defp collect_ancestors(category_id, by_id, acc) do
    case Map.fetch(by_id, category_id) do
      {:ok, %{parent_id: nil}} -> acc
      {:ok, %{parent_id: parent_id}} ->
        case Map.fetch(by_id, parent_id) do
          {:ok, parent} -> collect_ancestors(parent_id, by_id, [parent | acc])
          :error -> acc
        end
      :error -> acc
    end
  end

  defp collect_descendants(parent_id, by_parent, acc) do
    children = Map.get(by_parent, parent_id, [])

    Enum.reduce(children, acc, fn child, inner_acc ->
      collect_descendants(child.id, by_parent, [child.id | inner_acc])
    end)
  end

  defp cycle_present?(categories) do
    by_id = Map.new(categories, &{&1.id, &1})

    Enum.any?(categories, fn cat ->
      walk_to_root(cat.id, by_id, MapSet.new())
    end)
  end

  defp walk_to_root(id, by_id, visited) do
    cond do
      MapSet.member?(visited, id) -> true
      not Map.has_key?(by_id, id) -> false
      true ->
        cat = Map.fetch!(by_id, id)
        if is_nil(cat.parent_id) do
          false
        else
          walk_to_root(cat.parent_id, by_id, MapSet.put(visited, id))
        end
    end
  end

  defp to_crumb(category), do: %{name: category.name, slug: category.slug}
end
```
