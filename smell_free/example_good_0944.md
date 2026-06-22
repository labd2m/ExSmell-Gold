```elixir
defmodule Bst do
  @moduledoc """
  A purely functional, immutable binary search tree.

  All mutating operations (insert, delete) return a new tree root rather
  than updating in place. The tree maintains the BST invariant: all values
  in a node's left subtree are less than the node; all values in the right
  subtree are greater. Duplicate values are ignored on insert.

  The implementation uses plain tagged tuples for compactness. Callers
  interact through the module's typed API; the internal representation is
  intentionally opaque.
  """

  @type tree(v) :: nil | {v, tree(v), tree(v)}

  @spec new() :: tree(term())
  def new, do: nil

  @spec from_list([term()]) :: tree(term())
  def from_list(list) when is_list(list) do
    Enum.reduce(list, nil, &insert(&2, &1))
  end

  @spec insert(tree(v), v) :: tree(v) when v: term()
  def insert(nil, value), do: {value, nil, nil}
  def insert({value, left, right}, value), do: {value, left, right}
  def insert({node, left, right}, value) when value < node do
    {node, insert(left, value), right}
  end
  def insert({node, left, right}, value) do
    {node, left, insert(right, value)}
  end

  @spec member?(tree(v), v) :: boolean() when v: term()
  def member?(nil, _value), do: false
  def member?({value, _left, _right}, value), do: true
  def member?({node, left, _right}, value) when value < node, do: member?(left, value)
  def member?({_node, _left, right}, value), do: member?(right, value)

  @spec delete(tree(v), v) :: tree(v) when v: term()
  def delete(nil, _value), do: nil
  def delete({value, left, right}, value) do
    case {left, right} do
      {nil, nil} -> nil
      {nil, _} -> right
      {_, nil} -> left
      _ ->
        successor = min_value(right)
        {successor, left, delete(right, successor)}
    end
  end
  def delete({node, left, right}, value) when value < node do
    {node, delete(left, value), right}
  end
  def delete({node, left, right}, value) do
    {node, left, delete(right, value)}
  end

  @spec to_list(tree(v)) :: [v] when v: term()
  def to_list(nil), do: []
  def to_list({value, left, right}), do: to_list(left) ++ [value] ++ to_list(right)

  @spec min(tree(v)) :: {:ok, v} | {:error, :empty} when v: term()
  def min(nil), do: {:error, :empty}
  def min(tree), do: {:ok, min_value(tree)}

  @spec max(tree(v)) :: {:ok, v} | {:error, :empty} when v: term()
  def max(nil), do: {:error, :empty}
  def max({value, _left, nil}), do: {:ok, value}
  def max({_value, _left, right}), do: max(right)

  @spec size(tree(term())) :: non_neg_integer()
  def size(nil), do: 0
  def size({_value, left, right}), do: 1 + size(left) + size(right)

  @spec height(tree(term())) :: non_neg_integer()
  def height(nil), do: 0
  def height({_value, left, right}), do: 1 + max(height(left), height(right))

  @spec rank(tree(v), v) :: non_neg_integer() when v: term()
  def rank(tree, value), do: count_less_than(tree, value)

  @spec range(tree(v), v, v) :: [v] when v: term()
  def range(tree, low, high) do
    tree |> to_list() |> Enum.filter(&(&1 >= low and &1 <= high))
  end

  @spec floor(tree(v), v) :: {:ok, v} | {:error, :not_found} when v: term()
  def floor(nil, _value), do: {:error, :not_found}
  def floor({node, left, _right}, value) when value < node, do: floor(left, value)
  def floor({node, _left, right}, value) when value > node do
    case floor(right, value) do
      {:ok, _} = found -> found
      {:error, :not_found} -> {:ok, node}
    end
  end
  def floor({value, _left, _right}, value), do: {:ok, value}

  defp min_value({value, nil, _right}), do: value
  defp min_value({_value, left, _right}), do: min_value(left)

  defp count_less_than(nil, _value), do: 0
  defp count_less_than({node, left, right}, value) when value > node do
    1 + size(left) + count_less_than(right, value)
  end
  defp count_less_than({_node, left, _right}, value) do
    count_less_than(left, value)
  end
end
```
