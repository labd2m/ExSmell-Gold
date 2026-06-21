# File: `example_good_244.md`

```elixir
defmodule Search.InvertedIndex do
  @moduledoc """
  In-memory inverted index for full-text search over a small-to-medium
  document corpus.

  Documents are indexed as sets of normalised tokens. Lookups return
  document IDs ranked by the number of query terms matched, then by
  term frequency within each document.

  State is owned by an Agent; all public functions interact only through
  this module's API.
  """

  use Agent

  @type doc_id :: String.t()
  @type token :: String.t()
  @type index :: %{token() => %{doc_id() => pos_integer()}}

  @doc false
  def start_link(_opts) do
    Agent.start_link(fn -> %{index: %{}, doc_count: 0} end, name: __MODULE__)
  end

  @doc """
  Adds or replaces a document in the index.

  `content` is tokenised and normalised. Returns the count of unique
  tokens extracted from the document.
  """
  @spec index_document(doc_id(), String.t()) :: non_neg_integer()
  def index_document(doc_id, content) when is_binary(doc_id) and is_binary(content) do
    tokens = tokenize(content)
    frequencies = term_frequencies(tokens)

    Agent.update(__MODULE__, fn state ->
      new_index = add_to_index(state.index, doc_id, frequencies)
      %{state | index: new_index, doc_count: state.doc_count + 1}
    end)

    map_size(frequencies)
  end

  @doc """
  Removes a document from the index by ID.
  """
  @spec remove_document(doc_id()) :: :ok
  def remove_document(doc_id) when is_binary(doc_id) do
    Agent.update(__MODULE__, fn state ->
      new_index = Map.new(state.index, fn {token, postings} ->
        {token, Map.delete(postings, doc_id)}
      end)

      pruned = Map.reject(new_index, fn {_token, postings} -> map_size(postings) == 0 end)
      %{state | index: pruned}
    end)
  end

  @doc """
  Searches the index for documents matching any token in `query`.

  Results are ranked by the number of query tokens matched (descending),
  then by the sum of term frequencies (descending). Returns a list of
  `{doc_id, score}` tuples.
  """
  @spec search(String.t()) :: [{doc_id(), pos_integer()}]
  def search(query) when is_binary(query) do
    query_tokens = query |> tokenize() |> Enum.uniq()
    index = Agent.get(__MODULE__, & &1.index)

    query_tokens
    |> Enum.flat_map(fn token ->
      Map.get(index, token, %%) |> Enum.map(fn {doc_id, freq} -> {doc_id, freq} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {doc_id, freqs} -> {doc_id, length(freqs) * 100 + Enum.sum(freqs)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc """
  Returns the number of documents currently indexed.
  """
  @spec document_count() :: non_neg_integer()
  def document_count do
    Agent.get(__MODULE__, & &1.doc_count)
  end

  @doc """
  Returns the number of unique tokens in the index vocabulary.
  """
  @spec vocabulary_size() :: non_neg_integer()
  def vocabulary_size do
    Agent.get(__MODULE__, fn state -> map_size(state.index) end)
  end

  @doc """
  Checks whether the index contains any postings for `token`.
  """
  @spec indexed?(token()) :: boolean()
  def indexed?(token) when is_binary(token) do
    Agent.get(__MODULE__, fn state ->
      state.index |> Map.get(normalize(token), %{}) |> map_size() > 0
    end)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(byte_size(&1) < 2))
  end

  defp normalize(token), do: String.trim(token)

  defp term_frequencies(tokens) do
    Enum.reduce(tokens, %{}, fn token, acc ->
      Map.update(acc, token, 1, &(&1 + 1))
    end)
  end

  defp add_to_index(index, doc_id, frequencies) do
    Enum.reduce(frequencies, index, fn {token, freq}, acc ->
      Map.update(acc, token, %{doc_id => freq}, &Map.put(&1, doc_id, freq))
    end)
  end
end
```
