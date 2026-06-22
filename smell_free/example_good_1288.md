```elixir
defmodule Crdt.GCounter do
  @moduledoc """
  A grow-only distributed counter (G-Counter) that can be incremented on any
  node and merged without coordination.

  Each node tracks only its own increments. The total is the sum of all node
  values. Merging two replicas produces the element-wise maximum.
  """

  @enforce_keys [:node_id, :counts]
  defstruct [:node_id, :counts]

  @type node_id :: String.t()
  @type t :: %__MODULE__{
          node_id: node_id(),
          counts: %{node_id() => non_neg_integer()}
        }

  @doc """
  Creates a new zero-valued counter for the given node.
  """
  @spec new(node_id()) :: t()
  def new(node_id) when is_binary(node_id) do
    %__MODULE__{node_id: node_id, counts: %{node_id => 0}}
  end

  @doc """
  Increments the local node's count by the given amount (default 1).
  """
  @spec increment(t(), pos_integer()) :: t()
  def increment(%__MODULE__{node_id: nid, counts: counts} = counter, amount \\ 1)
      when is_integer(amount) and amount > 0 do
    current = Map.get(counts, nid, 0)
    %{counter | counts: Map.put(counts, nid, current + amount)}
  end

  @doc """
  Returns the global total across all nodes.
  """
  @spec value(t()) :: non_neg_integer()
  def value(%__MODULE__{counts: counts}) do
    counts |> Map.values() |> Enum.sum()
  end

  @doc """
  Returns the local increment contribution from this node only.
  """
  @spec local_value(t()) :: non_neg_integer()
  def local_value(%__MODULE__{node_id: nid, counts: counts}) do
    Map.get(counts, nid, 0)
  end

  @doc """
  Merges two G-Counter replicas by taking the element-wise maximum of each node's count.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{node_id: nid} = local, %__MODULE__{counts: remote_counts}) do
    merged =
      Map.merge(local.counts, remote_counts, fn _node, local_val, remote_val ->
        max(local_val, remote_val)
      end)

    %{local | counts: merged}
  end

  @doc """
  Returns true if `a` is causally dominated by or equal to `b`.

  That is, every node's count in `a` is <= the corresponding count in `b`.
  """
  @spec dominated_by?(t(), t()) :: boolean()
  def dominated_by?(%__MODULE__{counts: a_counts}, %__MODULE__{counts: b_counts}) do
    Enum.all?(a_counts, fn {node, a_val} ->
      b_val = Map.get(b_counts, node, 0)
      a_val <= b_val
    end)
  end

  @doc """
  Returns true if both counters have converged to the same state.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(a, b) do
    dominated_by?(a, b) and dominated_by?(b, a)
  end

  @doc """
  Returns the node IDs that have contributed increments to the counter.
  """
  @spec participating_nodes(t()) :: [node_id()]
  def participating_nodes(%__MODULE__{counts: counts}) do
    counts
    |> Enum.reject(fn {_node, val} -> val == 0 end)
    |> Enum.map(fn {node, _val} -> node end)
  end

  @doc """
  Serialises the counter to a plain map suitable for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{node_id: nid, counts: counts}) do
    %{node_id: nid, counts: counts}
  end

  @doc """
  Deserialises a counter from a plain map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{node_id: nid, counts: counts})
      when is_binary(nid) and is_map(counts) do
    {:ok, %__MODULE__{node_id: nid, counts: counts}}
  end

  def from_map(_), do: {:error, "invalid G-Counter map"}
end
```
