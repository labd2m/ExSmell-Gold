**File:** `example_good_1400.md`

```elixir
defmodule Tree.Node do
  @moduledoc "A node in a labeled, value-carrying n-ary tree."

  @enforce_keys [:label, :value]
  defstruct [:label, :value, children: []]

  @type t :: %__MODULE__{
          label: String.t(),
          value: term(),
          children: [t()]
        }

  @spec new(String.t(), term(), [t()]) :: t()
  def new(label, value, children \\ []) when is_binary(label) and is_list(children) do
    %__MODULE__{label: label, value: value, children: children}
  end

  @spec leaf?(t()) :: boolean()
  def leaf?(%__MODULE__{children: []}), do: true
  def leaf?(%__MODULE__{}), do: false
end

defmodule Tree do
  @moduledoc """
  Operations for traversing, transforming, and querying n-ary labeled trees.
  All functions are purely recursive and work on the `Tree.Node` struct.
  """

  alias Tree.Node

  @type path :: [String.t()]

  @spec map(Node.t(), (Node.t() -> term())) :: Node.t()
  def map(%Node{} = node, func) when is_function(func, 1) do
    mapped_children = Enum.map(node.children, &map(&1, func))
    %{node | value: func.(node), children: mapped_children}
  end

  @spec fold(Node.t(), term(), (Node.t(), term() -> term())) :: term()
  def fold(%Node{} = node, acc, func) when is_function(func, 2) do
    child_acc = Enum.reduce(node.children, acc, &fold(&1, &2, func))
    func.(node, child_acc)
  end

  @spec depth(Node.t()) :: non_neg_integer()
  def depth(%Node{children: []}), do: 0

  def depth(%Node{children: children}) do
    1 + Enum.max(Enum.map(children, &depth/1))
  end

  @spec size(Node.t()) :: pos_integer()
  def size(%Node{} = node) do
    fold(node, 0, fn _n, acc -> acc + 1 end)
  end

  @spec find(Node.t(), (Node.t() -> boolean())) :: {:ok, Node.t()} | :not_found
  def find(%Node{} = node, predicate) when is_function(predicate, 1) do
    if predicate.(node) do
      {:ok, node}
    else
      Enum.reduce_while(node.children, :not_found, fn child, _acc ->
        case find(child, predicate) do
          {:ok, found} -> {:halt, {:ok, found}}
          :not_found -> {:cont, :not_found}
        end
      end)
    end
  end

  @spec get_at_path(Node.t(), path()) :: {:ok, Node.t()} | {:error, :path_not_found}
  def get_at_path(%Node{} = node, []), do: {:ok, node}

  def get_at_path(%Node{children: children}, [label | rest]) do
    case Enum.find(children, &(&1.label == label)) do
      nil -> {:error, :path_not_found}
      child -> get_at_path(child, rest)
    end
  end

  @spec leaves(Node.t()) :: [Node.t()]
  def leaves(%Node{} = node) do
    fold(node, [], fn n, acc ->
      if Node.leaf?(n), do: [n | acc], else: acc
    end)
  end

  @spec paths_to_leaves(Node.t()) :: [path()]
  def paths_to_leaves(%Node{} = node) do
    collect_paths(node, [])
  end

  @spec prune(Node.t(), (Node.t() -> boolean())) :: Node.t()
  def prune(%Node{} = node, predicate) when is_function(predicate, 1) do
    kept_children =
      node.children
      |> Enum.reject(predicate)
      |> Enum.map(&prune(&1, predicate))

    %{node | children: kept_children}
  end

  @spec flatten_values(Node.t()) :: [term()]
  def flatten_values(%Node{} = node) do
    fold(node, [], fn n, acc -> [n.value | acc] end)
    |> Enum.reverse()
  end

  defp collect_paths(%Node{label: label, children: []}, current_path) do
    [Enum.reverse([label | current_path])]
  end

  defp collect_paths(%Node{label: label, children: children}, current_path) do
    Enum.flat_map(children, &collect_paths(&1, [label | current_path]))
  end
end
```
