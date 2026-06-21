```elixir
defmodule Catalog.SearchIndex do
  @moduledoc """
  Maintains an in-memory inverted index over product names and tags.
  Documents are indexed at write time so reads are O(term-count) lookups
  rather than full scans. Supports multi-term AND queries and returns
  results ranked by hit count descending.
  """

  use GenServer

  @type doc_id :: String.t()
  @type document :: %{id: doc_id(), text: String.t(), tags: [String.t()]}
  @type index_state :: %{
          index: %{String.t() => MapSet.t()},
          docs: %{doc_id() => document()}
        }

  @doc "Starts the search index registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Indexes a document, making it immediately searchable."
  @spec put(document()) :: :ok
  def put(%{id: _, text: _, tags: _} = doc) do
    GenServer.cast(__MODULE__, {:put, doc})
  end

  @doc "Removes a document from the index by its ID."
  @spec delete(doc_id()) :: :ok
  def delete(doc_id) when is_binary(doc_id) do
    GenServer.cast(__MODULE__, {:delete, doc_id})
  end

  @doc """
  Searches for documents matching all terms in `query`. Returns results
  ranked by number of matching terms, most relevant first.
  """
  @spec search(String.t()) :: [document()]
  def search(query) when is_binary(query) do
    GenServer.call(__MODULE__, {:search, query})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{index: %{}, docs: %{}}}

  @impl GenServer
  def handle_cast({:put, %{id: id} = doc}, state) do
    state_without_old = remove_from_index(state, id)
    terms = extract_terms(doc)
    new_index =
      Enum.reduce(terms, state_without_old.index, fn term, idx ->
        Map.update(idx, term, MapSet.new([id]), &MapSet.put(&1, id))
      end)
    {:noreply, %{state_without_old | index: new_index, docs: Map.put(state_without_old.docs, id, doc)}}
  end

  def handle_cast({:delete, doc_id}, state) do
    {:noreply, remove_from_index(state, doc_id)}
  end

  @impl GenServer
  def handle_call({:search, query}, _from, state) do
    terms = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    results =
      terms
      |> Enum.map(fn term -> Map.get(state.index, term, MapSet.new()) end)
      |> score_and_rank(terms, state.docs)

    {:reply, results, state}
  end

  defp score_and_rank(sets, terms, docs) do
    all_ids = Enum.reduce(sets, MapSet.new(), &MapSet.union/2)

    all_ids
    |> Enum.map(fn id ->
      hits = Enum.count(sets, &MapSet.member?(&1, id))
      {hits, Map.fetch!(docs, id)}
    end)
    |> Enum.sort_by(fn {hits, _} -> hits end, :desc)
    |> Enum.map(fn {_hits, doc} -> doc end)
  end

  defp extract_terms(%{text: text, tags: tags}) do
    text_terms = text |> String.downcase() |> String.split(~r/\W+/, trim: true)
    tag_terms = Enum.map(tags, &String.downcase/1)
    Enum.uniq(text_terms ++ tag_terms)
  end

  defp remove_from_index(%{index: index, docs: docs} = state, doc_id) do
    new_index =
      Map.new(index, fn {term, ids} -> {term, MapSet.delete(ids, doc_id)} end)
      |> Map.reject(fn {_term, ids} -> MapSet.size(ids) == 0 end)
    %{state | index: new_index, docs: Map.delete(docs, doc_id)}
  end
end
```
