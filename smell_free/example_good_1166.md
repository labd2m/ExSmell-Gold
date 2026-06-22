**File:** `example_good_1166.md`

```elixir
defmodule Search.Document do
  @moduledoc "Represents a document prepared for indexing into a search backend."

  @enforce_keys [:id, :index, :body]
  defstruct [:id, :index, :body, :boost, :tags]

  @type t :: %__MODULE__{
          id: String.t(),
          index: String.t(),
          body: map(),
          boost: float() | nil,
          tags: [String.t()]
        }

  @spec new(String.t(), String.t(), map(), keyword()) :: t()
  def new(id, index, body, opts \\ []) do
    %__MODULE__{
      id: id,
      index: index,
      body: body,
      boost: Keyword.get(opts, :boost),
      tags: Keyword.get(opts, :tags, [])
    }
  end
end

defmodule Search.Adapter do
  @moduledoc "Behaviour contract for search backend adapters."

  alias Search.Document

  @doc "Indexes a list of documents. Returns count of successfully indexed docs."
  @callback index_batch([Document.t()]) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Deletes a document by ID from a named index."
  @callback delete(String.t(), String.t()) :: :ok | {:error, term()}

  @doc "Searches an index with a query string and options."
  @callback search(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
end

defmodule Search.Adapters.Opensearch do
  @moduledoc "Search adapter backed by an OpenSearch cluster."

  @behaviour Search.Adapter

  alias Search.Document

  @impl Search.Adapter
  def index_batch(documents) when is_list(documents) do
    bulk_body = Enum.flat_map(documents, &build_index_action/1)

    case post_bulk(bulk_body) do
      {:ok, %{"errors" => false, "items" => items}} ->
        {:ok, length(items)}

      {:ok, %{"errors" => true} = resp} ->
        failed = count_failed_items(resp["items"])
        {:ok, length(documents) - failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Search.Adapter
  def delete(index, id) do
    case http_delete("#{index}/_doc/#{id}") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Search.Adapter
  def search(index, query_string, opts) do
    size = Keyword.get(opts, :size, 10)
    from = Keyword.get(opts, :from, 0)

    body = %{
      query: %{multi_match: %{query: query_string, fields: ["*"]}},
      size: size,
      from: from
    }

    case post_search(index, body) do
      {:ok, %{"hits" => %{"hits" => hits}}} ->
        {:ok, Enum.map(hits, & &1["_source"])}

      {:ok, _unexpected} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_index_action(%Document{id: id, index: index, body: body}) do
    [
      %{"index" => %{"_index" => index, "_id" => id}},
      body
    ]
  end

  defp count_failed_items(items) do
    Enum.count(items, fn item ->
      item |> Map.values() |> List.first() |> Map.get("error") != nil
    end)
  end

  defp post_bulk(_body), do: {:ok, %{"errors" => false, "items" => []}}
  defp post_search(_index, _body), do: {:ok, %{"hits" => %{"hits" => []}}}
  defp http_delete(_path), do: {:ok, %{}}
end

defmodule Search.Indexer do
  @moduledoc """
  Coordinates document indexing against a configured search adapter.
  Processes documents in batches and reports per-batch outcomes.
  """

  alias Search.{Adapter, Document}

  @default_batch_size 100

  @type result :: %{indexed: non_neg_integer(), failed: non_neg_integer()}

  @spec index_all([Document.t()], module(), keyword()) :: result()
  def index_all(documents, adapter, opts \\ [])
      when is_list(documents) and is_atom(adapter) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    documents
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce(%{indexed: 0, failed: 0}, fn batch, acc ->
      process_batch(batch, adapter, acc)
    end)
  end

  defp process_batch(batch, adapter, acc) do
    case adapter.index_batch(batch) do
      {:ok, count} ->
        failed = length(batch) - count
        %{indexed: acc.indexed + count, failed: acc.failed + failed}

      {:error, _reason} ->
        %{acc | failed: acc.failed + length(batch)}
    end
  end
end
```
