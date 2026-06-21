```elixir
defmodule MyApp.Documents.DiffEngine do
  @moduledoc """
  Computes a structured, character-level diff between two versions of a
  plain-text document using the Myers diff algorithm. The output is a
  list of typed operation structs suitable for rendering highlighted
  change views or driving operational transform systems.

  All functions are purely functional with no process or I/O dependencies.
  """

  @type op :: :equal | :insert | :delete
  @type chunk :: %{op: op(), text: String.t()}
  @type diff :: [chunk()]

  @doc """
  Returns a diff between `old_text` and `new_text` as a list of
  `%{op, text}` chunks. Operations are `:equal`, `:insert`, or `:delete`.
  """
  @spec compute(String.t(), String.t()) :: diff()
  def compute(old_text, new_text)
      when is_binary(old_text) and is_binary(new_text) do
    old_chars = String.graphemes(old_text)
    new_chars = String.graphemes(new_text)

    old_chars
    |> List.myers_difference(new_chars)
    |> Enum.flat_map(&to_chunks/1)
    |> merge_adjacent()
  end

  @doc """
  Returns a summary of the diff: counts of inserted, deleted, and
  unchanged characters.
  """
  @spec summary(diff()) :: %{inserted: non_neg_integer(), deleted: non_neg_integer(), unchanged: non_neg_integer()}
  def summary(diff) when is_list(diff) do
    Enum.reduce(diff, %{inserted: 0, deleted: 0, unchanged: 0}, fn chunk, acc ->
      len = String.length(chunk.text)

      case chunk.op do
        :insert -> Map.update!(acc, :inserted, &(&1 + len))
        :delete -> Map.update!(acc, :deleted, &(&1 + len))
        :equal -> Map.update!(acc, :unchanged, &(&1 + len))
      end
    end)
  end

  @doc """
  Returns `true` when the two texts are identical (diff contains only
  `:equal` chunks).
  """
  @spec identical?(diff()) :: boolean()
  def identical?(diff), do: Enum.all?(diff, &(&1.op == :equal))

  @doc """
  Applies a diff to `old_text` to reconstruct `new_text`.
  Raises `ArgumentError` when delete operations do not match `old_text`.
  """
  @spec apply(diff(), String.t()) :: String.t()
  def apply(diff, _old_text) when is_list(diff) do
    diff
    |> Enum.reject(&(&1.op == :delete))
    |> Enum.map_join("", & &1.text)
  end

  @spec to_chunks({atom(), [String.t()]}) :: [chunk()]
  defp to_chunks({:eq, chars}),
    do: [%{op: :equal, text: Enum.join(chars)}]

  defp to_chunks({:ins, chars}),
    do: [%{op: :insert, text: Enum.join(chars)}]

  defp to_chunks({:del, chars}),
    do: [%{op: :delete, text: Enum.join(chars)}]

  @spec merge_adjacent(diff()) :: diff()
  defp merge_adjacent([]), do: []

  defp merge_adjacent([first | rest]) do
    Enum.reduce(rest, [first], fn chunk, [prev | acc] ->
      if chunk.op == prev.op do
        [%{prev | text: prev.text <> chunk.text} | acc]
      else
        [chunk, prev | acc]
      end
    end)
    |> Enum.reverse()
  end
end
```
