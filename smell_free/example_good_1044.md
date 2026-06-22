```elixir
defmodule Search.Index.DocumentStore do
  @moduledoc """
  An in-memory document store backed by a supervised GenServer.
  Supports insertion, retrieval, and full-text search across stored documents.
  All state mutations go through this module's public API; callers have no
  direct knowledge of the underlying Agent or process internals.
  """

  use GenServer

  alias Search.Index.Document

  @type state :: %{documents: %{String.t() => Document.t()}}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Starts the DocumentStore and links it to the calling supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{documents: %{}}, name: name)
  end

  @doc "Inserts or replaces a document by its ID."
  @spec put(GenServer.server(), Document.t()) :: :ok
  def put(server \\ __MODULE__, %Document{} = doc) do
    GenServer.call(server, {:put, doc})
  end

  @doc "Retrieves a document by ID. Returns `{:error, :not_found}` if absent."
  @spec get(GenServer.server(), String.t()) :: {:ok, Document.t()} | {:error, :not_found}
  def get(server \\ __MODULE__, id) when is_binary(id) do
    GenServer.call(server, {:get, id})
  end

  @doc "Deletes a document by ID. Returns `:ok` regardless of prior existence."
  @spec delete(GenServer.server(), String.t()) :: :ok
  def delete(server \\ __MODULE__, id) when is_binary(id) do
    GenServer.call(server, {:delete, id})
  end

  @doc """
  Searches all documents for those whose body contains `query` (case-insensitive).
  Returns a list of matching documents sorted by title.
  """
  @spec search(GenServer.server(), String.t()) :: [Document.t()]
  def search(server \\ __MODULE__, query) when is_binary(query) do
    GenServer.call(server, {:search, query})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(initial_state), do: {:ok, initial_state}

  @impl GenServer
  def handle_call({:put, doc}, _from, state) do
    updated = put_in(state, [:documents, doc.id], doc)
    {:reply, :ok, updated}
  end

  def handle_call({:get, id}, _from, state) do
    result =
      case Map.fetch(state.documents, id) do
        {:ok, doc} -> {:ok, doc}
        :error -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, id}, _from, state) do
    updated = update_in(state, [:documents], &Map.delete(&1, id))
    {:reply, :ok, updated}
  end

  def handle_call({:search, query}, _from, state) do
    downcased = String.downcase(query)

    matches =
      state.documents
      |> Map.values()
      |> Enum.filter(&document_matches?(&1, downcased))
      |> Enum.sort_by(& &1.title)

    {:reply, matches, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec document_matches?(Document.t(), String.t()) :: boolean()
  defp document_matches?(%Document{body: body, title: title}, query) do
    String.contains?(String.downcase(body), query) or
      String.contains?(String.downcase(title), query)
  end
end

defmodule Search.Index.Document do
  @moduledoc "Represents an indexed document in the search store."

  @enforce_keys [:id, :title, :body]
  defstruct [:id, :title, :body, tags: [], inserted_at: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          body: String.t(),
          tags: [String.t()],
          inserted_at: DateTime.t() | nil
        }
end
```
