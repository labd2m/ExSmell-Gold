```elixir
defmodule Search.IndexManager do
  @moduledoc """
  GenServer responsible for managing the lifecycle of a document search index.

  Accepts document upserts and deletions, applies them to an in-memory index
  maintained as a structured ETS table, and exposes a keyword search query
  interface. Designed to be placed under a named application supervisor.
  """

  use GenServer

  @table :search_index

  @type doc_id :: String.t()
  @type document :: %{id: doc_id(), title: String.t(), body: String.t(), tags: [String.t()]}
  @type search_result :: %{id: doc_id(), title: String.t(), score: float()}

  @doc """
  Starts the index manager as a named, linked process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Indexes or updates a document by its ID.
  """
  @spec upsert_document(document()) :: :ok
  def upsert_document(%{id: _} = document) do
    GenServer.cast(__MODULE__, {:upsert, document})
  end

  @doc """
  Removes a document from the index by its ID.
  """
  @spec delete_document(doc_id()) :: :ok
  def delete_document(doc_id) when is_binary(doc_id) do
    GenServer.cast(__MODULE__, {:delete, doc_id})
  end

  @doc """
  Searches the index for documents matching the given keyword query.

  Returns a list of result maps sorted by descending relevance score.
  """
  @spec query(String.t()) :: [search_result()]
  def query(keyword) when is_binary(keyword) and keyword != "" do
    GenServer.call(__MODULE__, {:query, keyword})
  end

  def query(_keyword), do: []

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:upsert, document}, state) do
    indexed = build_indexed_document(document)
    :ets.insert(@table, {document.id, indexed})
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:delete, doc_id}, state) do
    :ets.delete(@table, doc_id)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:query, keyword}, _from, state) do
    results =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, doc} -> score_document(doc, keyword) end)
      |> Enum.reject(fn %{score: score} -> score == 0.0 end)
      |> Enum.sort_by(fn %{score: score} -> score end, :desc)
      |> Enum.map(fn %{id: id, title: title, score: score} ->
        %{id: id, title: title, score: score}
      end)

    {:reply, results, state}
  end

  defp build_indexed_document(%{id: id, title: title, body: body, tags: tags}) do
    %{
      id: id,
      title: title,
      tokens: tokenize("#{title} #{body} #{Enum.join(tags, " ")}")
    }
  end

  defp score_document(%{id: id, title: title, tokens: tokens}, keyword) do
    keyword_tokens = tokenize(keyword)

    match_count =
      Enum.count(keyword_tokens, fn kw_token ->
        Enum.any?(tokens, &String.contains?(&1, kw_token))
      end)

    score = if length(keyword_tokens) > 0, do: match_count / length(keyword_tokens), else: 0.0

    %{id: id, title: title, score: score}
  end

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.uniq()
  end
end
```
