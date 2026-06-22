```elixir
defmodule Catalog.SearchIndex do
  @moduledoc """
  In-memory inverted index for fast full-text product search across name and description fields.
  Supports multi-term queries with ranked results by term frequency score.
  """

  use GenServer

  @type product_id :: String.t()
  @type term :: String.t()
  @type index :: %{term() => MapSet.t(product_id())}
  @type document :: %{id: product_id(), name: String.t(), description: String.t(), weight: pos_integer()}
  @type scored_result :: %{product_id: product_id(), score: float()}
  @type state :: %{index: index(), documents: %{product_id() => document()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{index: %{}, documents: %{}}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec index_document(document()) :: :ok
  def index_document(%{id: id} = document) when is_binary(id) do
    GenServer.call(__MODULE__, {:index, document})
  end

  @spec remove_document(product_id()) :: :ok
  def remove_document(product_id) when is_binary(product_id) do
    GenServer.call(__MODULE__, {:remove, product_id})
  end

  @spec search(String.t(), keyword()) :: [scored_result()]
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    GenServer.call(__MODULE__, {:search, query, limit})
  end

  @spec document_count() :: non_neg_integer()
  def document_count, do: GenServer.call(__MODULE__, :count)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:index, document}, _from, state) do
    terms = extract_terms(document)
    new_index = Enum.reduce(terms, state.index, fn term, acc ->
      Map.update(acc, term, MapSet.new([document.id]), &MapSet.put(&1, document.id))
    end)
    new_docs = Map.put(state.documents, document.id, document)
    {:reply, :ok, %{state | index: new_index, documents: new_docs}}
  end

  def handle_call({:remove, product_id}, _from, state) do
    new_index =
      Map.new(state.index, fn {term, ids} ->
        {term, MapSet.delete(ids, product_id)}
      end)
      |> Map.reject(fn {_, ids} -> MapSet.size(ids) == 0 end)

    new_docs = Map.delete(state.documents, product_id)
    {:reply, :ok, %{state | index: new_index, documents: new_docs}}
  end

  def handle_call({:search, query, limit}, _from, state) do
    results =
      query
      |> tokenize()
      |> Enum.reject(&(&1 == ""))
      |> score_documents(state.index, state.documents)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    {:reply, results, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state.documents), state}
  end

  @spec score_documents([term()], index(), %{product_id() => document()}) :: [scored_result()]
  defp score_documents([], _index, _documents), do: []

  defp score_documents(query_terms, index, documents) do
    query_terms
    |> Enum.flat_map(&matching_ids(&1, index))
    |> Enum.frequencies()
    |> Enum.map(fn {product_id, hit_count} ->
      doc = Map.fetch!(documents, product_id)
      tf_score = hit_count / length(query_terms)
      weight_bonus = :math.log(doc.weight + 1)
      %{product_id: product_id, score: Float.round(tf_score * weight_bonus, 4)}
    end)
  end

  @spec matching_ids(term(), index()) :: [product_id()]
  defp matching_ids(term, index) do
    index
    |> Map.get(term, MapSet.new())
    |> MapSet.to_list()
  end

  @spec extract_terms(document()) :: [term()]
  defp extract_terms(%{name: name, description: description}) do
    (tokenize(name) ++ tokenize(description))
    |> Enum.uniq()
  end

  @spec tokenize(String.t()) :: [term()]
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.reject(&stop_word?/1)
  end

  @stop_words ~w(a an the is are was were be been being have has had do does did will would could should may might of in on at to for with by from)

  @spec stop_word?(term()) :: boolean()
  defp stop_word?(word), do: word in @stop_words
end
```
