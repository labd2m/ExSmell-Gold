```elixir
defmodule Crdt.GCounter do
  @moduledoc """
  An implementation of a Grow-only Counter (G-Counter) CRDT for eventually
  consistent distributed tallies. Each node maintains its own increment slot
  keyed by node name; merging two replicas produces the maximum of each
  corresponding slot. The global value is the sum across all slots.
  G-Counters can only grow: decrement support requires a separate PN-Counter
  (not implemented here). This pure-functional module has no process or
  I/O dependencies and can be tested exhaustively with property-based tests.
  """

  @type node_id :: binary() | atom()
  @type t :: %__MODULE__{
          slots: %{node_id() => non_neg_integer()}
        }

  @enforce_keys [:slots]
  defstruct [:slots]

  @doc """
  Creates a new zero-value G-Counter.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{slots: %{}}

  @doc """
  Increments the counter for `node_id` by `amount`.
  """
  @spec increment(t(), node_id(), pos_integer()) :: t()
  def increment(%__MODULE__{} = counter, node_id, amount \\ 1)
      when (is_binary(node_id) or is_atom(node_id)) and is_integer(amount) and amount > 0 do
    updated_slots = Map.update(counter.slots, node_id, amount, &(&1 + amount))
    %__MODULE__{counter | slots: updated_slots}
  end

  @doc """
  Returns the current aggregate value of the counter across all nodes.
  """
  @spec value(t()) :: non_neg_integer()
  def value(%__MODULE__{slots: slots}) do
    Map.values(slots) |> Enum.sum()
  end

  @doc """
  Merges `a` and `b` by taking the element-wise maximum of each slot.
  The result represents the most up-to-date observed count.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{slots: a_slots}, %__MODULE__{slots: b_slots}) do
    merged =
      Map.merge(a_slots, b_slots, fn _node, va, vb -> max(va, vb) end)

    %__MODULE__{slots: merged}
  end

  @doc """
  Returns `true` when `a` is dominated by or equal to `b` — every slot in `a`
  is less than or equal to the corresponding slot in `b`.
  Used to detect stale replicas.
  """
  @spec dominated_by?(t(), t()) :: boolean()
  def dominated_by?(%__MODULE__{slots: a_slots}, %__MODULE__{slots: b_slots}) do
    Enum.all?(a_slots, fn {node, a_val} ->
      b_val = Map.get(b_slots, node, 0)
      a_val <= b_val
    end)
  end

  @doc """
  Returns `true` when `a` and `b` are equivalent (same per-node counts).
  """
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(%__MODULE__{} = a, %__MODULE__{} = b) do
    dominated_by?(a, b) and dominated_by?(b, a)
  end

  @doc """
  Returns the per-node breakdown of increments for diagnostic tooling.
  """
  @spec breakdown(t()) :: %{node_id() => non_neg_integer()}
  def breakdown(%__MODULE__{slots: slots}), do: slots

  @doc """
  Serialises the counter to a plain map for persistence or network transfer.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{slots: slots}) do
    %{
      type: "g_counter",
      slots: Map.new(slots, fn {k, v} -> {to_string(k), v} end)
    }
  end

  @doc """
  Deserialises a counter from a plain map produced by `to_map/1`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_format}
  def from_map(%{"type" => "g_counter", "slots" => slots}) when is_map(slots) do
    parsed_slots =
      Map.new(slots, fn {k, v} when is_binary(k) and is_integer(v) and v >= 0 -> {k, v} end)

    {:ok, %__MODULE__{slots: parsed_slots}}
  rescue
    _ -> {:error, :invalid_format}
  end

  def from_map(_), do: {:error, :invalid_format}
end
```
