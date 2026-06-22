```elixir
defmodule Catalog.CategoryTree do
  @moduledoc """
  Builds and traverses a hierarchical category tree from a flat list of
  database records. Provides path resolution, subtree extraction, and
  breadcrumb generation without recursive database queries.
  """

  @type category_id :: pos_integer()

  @type node :: %{
          id: category_id(),
          name: String.t(),
          slug: String.t(),
          parent_id: category_id() | nil,
          depth: non_neg_integer(),
          children: [node()]
        }

  @type flat_category :: %{
          id: category_id(),
          name: String.t(),
          slug: String.t(),
          parent_id: category_id() | nil
        }

  @spec build([flat_category()]) :: [node()]
  def build(flat_categories) when is_list(flat_categories) do
    index = Map.new(flat_categories, &{&1.id, &1})

    flat_categories
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Enum.map(&expand_node(&1, index, 0))
    |> Enum.sort_by(& &1.name)
  end

  @spec find(category_id(), [node()]) :: {:ok, node()} | {:error, :not_found}
  def find(id, tree) when is_integer(id) do
    case depth_first_search(id, tree) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  @spec subtree(category_id(), [node()]) :: {:ok, [node()]} | {:error, :not_found}
  def subtree(id, tree) when is_integer(id) do
    case find(id, tree) do
      {:ok, node} -> {:ok, node.children}
      {:error, _} = err -> err
    end
  end

  @spec breadcrumbs(category_id(), [flat_category()]) :: {:ok, [flat_category()]} | {:error, :not_found}
  def breadcrumbs(id, flat_categories) when is_integer(id) do
    index = Map.new(flat_categories, &{&1.id, &1})

    case Map.fetch(index, id) do
      :error -> {:error, :not_found}
      {:ok, _} -> {:ok, build_breadcrumb_path(id, index, [])}
    end
  end

  @spec ancestors(category_id(), [flat_category()]) :: [flat_category()]
  def ancestors(id, flat_categories) when is_integer(id) do
    index = Map.new(flat_categories, &{&1.id, &1})
    build_breadcrumb_path(id, index, []) |> Enum.drop(-1)
  end

  @spec leaf_ids([node()]) :: [category_id()]
  def leaf_ids(tree) when is_list(tree) do
    Enum.flat_map(tree, &collect_leaves/1)
  end

  @spec expand_node(flat_category(), %{category_id() => flat_category()}, non_neg_integer()) ::
          node()
  defp expand_node(category, index, depth) do
    children =
      index
      |> Map.values()
      |> Enum.filter(&(&1.parent_id == category.id))
      |> Enum.map(&expand_node(&1, index, depth + 1))
      |> Enum.sort_by(& &1.name)

    Map.merge(category, %{depth: depth, children: children})
  end

  @spec depth_first_search(category_id(), [node()]) :: node() | nil
  defp depth_first_search(_id, []), do: nil

  defp depth_first_search(id, [node | rest]) do
    cond do
      node.id == id -> node
      node.children != [] -> depth_first_search(id, node.children) || depth_first_search(id, rest)
      true -> depth_first_search(id, rest)
    end
  end

  @spec build_breadcrumb_path(category_id(), %{category_id() => flat_category()}, [flat_category()]) ::
          [flat_category()]
  defp build_breadcrumb_path(nil, _index, acc), do: acc

  defp build_breadcrumb_path(id, index, acc) do
    case Map.fetch(index, id) do
      {:ok, category} -> build_breadcrumb_path(category.parent_id, index, [category | acc])
      :error -> acc
    end
  end

  @spec collect_leaves(node()) :: [category_id()]
  defp collect_leaves(%{children: [], id: id}), do: [id]
  defp collect_leaves(%{children: children}), do: Enum.flat_map(children, &collect_leaves/1)
end
```
