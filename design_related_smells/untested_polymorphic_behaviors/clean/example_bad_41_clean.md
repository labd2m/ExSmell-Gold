```elixir
defmodule Inventory.CategoryTree do
  @moduledoc """
  Manages the hierarchical product category tree used for catalog navigation,
  search filtering, and inventory partitioning.
  """

  alias Inventory.{Category, Product}

  @max_depth 6
  @separator "/"

  def insert_category(tree, %Category{} = category) do
    path_segments = build_category_path(category.ancestry)

    case validate_depth(path_segments) do
      :ok ->
        node = %{
          id: category.id,
          name: category.name,
          slug: category.slug,
          path: path_segments,
          children: [],
          product_count: 0
        }

        {:ok, put_in_tree(tree, String.split(path_segments, @separator), node)}

      {:error, _} = err ->
        err
    end
  end

  def build_category_path(segments) do
    segments
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(@separator)
  end

  def validate_depth(path) when is_binary(path) do
    depth = path |> String.split(@separator) |> length()

    if depth <= @max_depth do
      :ok
    else
      {:error, {:max_depth_exceeded, depth, @max_depth}}
    end
  end

  def find_category(tree, path) when is_binary(path) do
    keys = String.split(path, @separator)
    get_in_tree(tree, keys)
  end

  def list_children(tree, parent_path) when is_binary(parent_path) do
    case find_category(tree, parent_path) do
      nil -> {:error, :parent_not_found}
      node -> {:ok, node.children}
    end
  end

  def move_category(tree, from_path, to_path) do
    with {:ok, node} <- find_node_or_error(tree, from_path),
         :ok <- validate_depth(to_path) do
      tree
      |> remove_from_tree(from_path)
      |> insert_at_tree(to_path, %{node | path: to_path})
      |> then(&{:ok, &1})
    end
  end

  def product_paths_for_category(tree, category_path) do
    case find_category(tree, category_path) do
      nil ->
        {:error, :category_not_found}

      node ->
        paths =
          Product.list_by_category(node.id)
          |> Enum.map(fn product ->
            "#{category_path}/#{product.slug}"
          end)

        {:ok, paths}
    end
  end

  defp put_in_tree(tree, [head | []], node) do
    Map.put(tree, head, node)
  end

  defp put_in_tree(tree, [head | tail], node) do
    subtree = Map.get(tree, head, %{})
    Map.put(tree, head, put_in_tree(subtree, tail, node))
  end

  defp get_in_tree(_tree, []), do: nil

  defp get_in_tree(tree, [head | []]), do: Map.get(tree, head)

  defp get_in_tree(tree, [head | tail]) do
    case Map.get(tree, head) do
      nil -> nil
      subtree -> get_in_tree(subtree, tail)
    end
  end

  defp find_node_or_error(tree, path) do
    case find_category(tree, path) do
      nil -> {:error, {:not_found, path}}
      node -> {:ok, node}
    end
  end

  defp remove_from_tree(tree, _path), do: tree
  defp insert_at_tree(tree, _path, _node), do: tree
end
```
