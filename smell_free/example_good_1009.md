```elixir
defmodule Trie do
  @moduledoc """
  A purely functional prefix tree (trie) for efficient string lookup
  and prefix-based autocomplete.

  Each node is a map of character strings to child nodes, plus a boolean
  marking whether the node represents the end of a complete word. All
  operations return new tries; the original is never mutated. Autocomplete
  performs a depth-first traversal from the prefix node, collecting all
  complete words reachable from that point.
  """

  @type t :: %__MODULE__{children: %{String.t() => t()}, terminal: boolean()}

  defstruct children: %{}, terminal: false

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{} = trie, word) when is_binary(word) do
    do_insert(trie, String.graphemes(word))
  end

  @spec search(t(), String.t()) :: boolean()
  def search(%__MODULE__{} = trie, word) when is_binary(word) do
    case traverse(trie, String.graphemes(word)) do
      {:ok, node} -> node.terminal
      :not_found -> false
    end
  end

  @spec starts_with?(t(), String.t()) :: boolean()
  def starts_with?(%__MODULE__{} = trie, prefix) when is_binary(prefix) do
    case traverse(trie, String.graphemes(prefix)) do
      {:ok, _node} -> true
      :not_found -> false
    end
  end

  @spec autocomplete(t(), String.t(), pos_integer()) :: [String.t()]
  def autocomplete(%__MODULE__{} = trie, prefix, limit \\ 10)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    case traverse(trie, String.graphemes(prefix)) do
      {:ok, node} ->
        collect_words(node, prefix, [], limit) |> Enum.sort()

      :not_found ->
        []
    end
  end

  @spec delete(t(), String.t()) :: t()
  def delete(%__MODULE__{} = trie, word) when is_binary(word) do
    do_delete(trie, String.graphemes(word))
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = trie) do
    base = if trie.terminal, do: 1, else: 0
    Enum.reduce(trie.children, base, fn {_, child}, acc -> acc + size(child) end)
  end

  @spec to_list(t()) :: [String.t()]
  def to_list(%__MODULE__{} = trie), do: collect_words(trie, "", [], :infinity)

  defp do_insert(%__MODULE__{} = node, []) do
    %{node | terminal: true}
  end

  defp do_insert(%__MODULE__{} = node, [ch | rest]) do
    child = Map.get(node.children, ch, %__MODULE__{})
    updated_child = do_insert(child, rest)
    %{node | children: Map.put(node.children, ch, updated_child)}
  end

  defp traverse(node, []), do: {:ok, node}

  defp traverse(%__MODULE__{children: children}, [ch | rest]) do
    case Map.fetch(children, ch) do
      {:ok, child} -> traverse(child, rest)
      :error -> :not_found
    end
  end

  defp collect_words(_node, _prefix, acc, limit) when length(acc) >= limit, do: acc

  defp collect_words(%__MODULE__{terminal: true, children: children}, prefix, acc, limit) do
    acc = [prefix | acc]
    collect_from_children(children, prefix, acc, limit)
  end

  defp collect_words(%__MODULE__{children: children}, prefix, acc, limit) do
    collect_from_children(children, prefix, acc, limit)
  end

  defp collect_from_children(children, prefix, acc, limit) do
    Enum.reduce_while(children, acc, fn {ch, child}, inner_acc ->
      if length(inner_acc) >= limit do
        {:halt, inner_acc}
      else
        {:cont, collect_words(child, prefix <> ch, inner_acc, limit)}
      end
    end)
  end

  defp do_delete(%__MODULE__{} = node, []) do
    %{node | terminal: false}
  end

  defp do_delete(%__MODULE__{} = node, [ch | rest]) do
    case Map.fetch(node.children, ch) do
      {:ok, child} ->
        updated = do_delete(child, rest)
        if updated.terminal == false and map_size(updated.children) == 0 do
          %{node | children: Map.delete(node.children, ch)}
        else
          %{node | children: Map.put(node.children, ch, updated)}
        end

      :error ->
        node
    end
  end
end
```
