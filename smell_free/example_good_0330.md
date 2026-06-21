```elixir
defmodule Tree.Node do
  @moduledoc """
  A single node in an N-ary (rose) tree carrying an arbitrary value
  and a list of zero or more child nodes.
  """

  @type t(v) :: %__MODULE__{value: v, children: [t(v)]}

  defstruct [:value, children: []]

  @spec leaf(term()) :: t(term())
  def leaf(value), do: %__MODULE__{value: value}

  @spec branch(term(), [t(term())]) :: t(term())
  def branch(value, children) when is_list(children) do
    %__MODULE__{value: value, children: children}
  end
end

defmodule Tree do
  @moduledoc """
  Pure functional operations on N-ary rose trees.

  All traversal functions are non-recursive in their outer loop to avoid
  stack overflow on deep trees; they instead use an explicit work stack
  (`depth_first/1`) or a queue (`breadth_first/1`). Higher-order functions
  follow the same shape as `Enum` to compose naturally with the standard
  library.
  """

  alias Tree.Node

  @spec depth_first(Node.t(v)) :: [v] when v: term()
  def depth_first(%Node{} = root) do
    do_dfs([root], [])
  end

  @spec breadth_first(Node.t(v)) :: [v] when v: term()
  def breadth_first(%Node{} = root) do
    do_bfs(:queue.from_list([root]), [])
  end

  @spec map(Node.t(a), (a -> b)) :: Node.t(b) when a: term(), b: term()
  def map(%Node{value: v, children: children}, fun) when is_function(fun, 1) do
    %Node{value: fun.(v), children: Enum.map(children, &map(&1, fun))}
  end

  @spec reduce(Node.t(v), acc, (v, acc -> acc)) :: acc when v: term(), acc: term()
  def reduce(%Node{value: v, children: children}, acc, fun) when is_function(fun, 2) do
    child_acc = Enum.reduce(children, acc, fn child, a -> reduce(child, a, fun) end)
    fun.(v, child_acc)
  end

  @spec find(Node.t(v), (v -> boolean())) :: {:ok, v} | :not_found when v: term()
  def find(%Node{} = root, predicate) when is_function(predicate, 1) do
    root
    |> depth_first()
    |> Enum.find(:not_found, predicate)
    |> case do
      :not_found -> :not_found
      value -> {:ok, value}
    end
  end

  @spec depth(Node.t(term())) :: non_neg_integer()
  def depth(%Node{children: []}), do: 0

  def depth(%Node{children: children}) do
    1 + Enum.reduce(children, 0, fn child, max_d -> max(max_d, depth(child)) end)
  end

  @spec size(Node.t(term())) :: pos_integer()
  def size(%Node{} = root) do
    reduce(root, 0, fn _v, acc -> acc + 1 end)
  end

  @spec leaves(Node.t(v)) :: [v] when v: term()
  def leaves(%Node{children: [], value: v}), do: [v]
  def leaves(%Node{children: children}), do: Enum.flat_map(children, &leaves/1)

  defp do_dfs([], acc), do: Enum.reverse(acc)

  defp do_dfs([%Node{value: v, children: children} | rest], acc) do
    do_dfs(children ++ rest, [v | acc])
  end

  defp do_bfs(queue, acc) do
    case :queue.out(queue) do
      {:empty, _} ->
        Enum.reverse(acc)

      {{:value, %Node{value: v, children: children}}, remaining} ->
        updated = Enum.reduce(children, remaining, fn child, q -> :queue.in(child, q) end)
        do_bfs(updated, [v | acc])
    end
  end
end
```
