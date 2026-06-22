```elixir
defmodule Search.Index.DocumentStore do
  @moduledoc """
  An ETS-backed in-memory document store supporting full-text term indexing.
  Documents are stored by ID; an inverted index maps terms to document IDs.
  """

  use GenServer

  @type doc_id :: String.t()
  @type document :: %{id: doc_id(), title: String.t(), body: String.t()}
  @type state :: %{docs: :ets.tab(), inverted_index: :ets.tab()}

  @doc """
  Starts the DocumentStore linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Indexes a document and stores it. Replaces any existing document with the same ID.
  """
  @spec index(document()) :: :ok | {:error, String.t()}
  def index(%{id: id, title: title, body: body} = doc)
      when is_binary(id) and is_binary(title) and is_binary(body) do
    GenServer.call(__MODULE__, {:index, doc})
  end

  def index(_invalid), do: {:error, "document must have binary id, title, and body fields"}

  @doc """
  Searches for documents containing all provided terms (AND semantics).
  Returns a list of matching documents.
  """
  @spec search([String.t()]) :: [document()]
  def search(terms) when is_list(terms) do
    GenServer.call(__MODULE__, {:search, terms})
  end

  @doc """
  Removes a document by ID from both the store and inverted index.
  """
  @spec delete(doc_id()) :: :ok
  def delete(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @impl GenServer
  def init(_opts) do
    docs = :ets.new(:document_store_docs, [:set, :private])
    inverted_index = :ets.new(:document_store_index, [:bag, :private])
    {:ok, %{docs: docs, inverted_index: inverted_index}}
  end

  @impl GenServer
  def handle_call({:index, doc}, _from, state) do
    remove_from_index(state.inverted_index, doc.id)
    :ets.insert(state.docs, {doc.id, doc})
    tokenize(doc.title <> " " <> doc.body)
    |> Enum.each(fn term -> :ets.insert(state.inverted_index, {term, doc.id}) end)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:search, terms}, _from, state) do
    normalized = Enum.map(terms, &normalize_term/1)

    matching_ids =
      normalized
      |> Enum.map(fn term ->
        :ets.lookup(state.inverted_index, term) |> Enum.map(fn {_, id} -> id end) |> MapSet.new()
      end)
      |> intersect_all()

    docs =
      matching_ids
      |> Enum.flat_map(fn id ->
        case :ets.lookup(state.docs, id) do
          [{^id, doc}] -> [doc]
          [] -> []
        end
      end)

    {:reply, docs, state}
  end

  @impl GenServer
  def handle_call({:delete, id}, _from, state) do
    remove_from_index(state.inverted_index, id)
    :ets.delete(state.docs, id)
    {:reply, :ok, state}
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/\W+/, trim: true)
    |> Enum.uniq()
  end

  defp normalize_term(term) when is_binary(term), do: String.downcase(String.trim(term))

  defp remove_from_index(table, doc_id) do
    :ets.match_delete(table, {:_, doc_id})
  end

  defp intersect_all([]), do: MapSet.new()
  defp intersect_all([head | tail]), do: Enum.reduce(tail, head, &MapSet.intersection(&2, &1))
end
```
