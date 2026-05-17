# Annotated Example 41 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Search.Indexer` declarations
- **Affected functions:** `Search.Indexer.index_document/3`, `Search.Indexer.delete_document/2`, `Search.Indexer.bulk_index/2`, `Search.Indexer.reindex_collection/2`, `Search.Indexer.mapping/1`
- **Short explanation:** Two separate source files both declare `defmodule Search.Indexer`. BEAM silently discards the first definition when the second is loaded, making all functions from the overwritten version permanently inaccessible and causing search index operations to fail at runtime.

---

```elixir
# ── file: lib/search/indexer.ex ─────────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Search.Indexer` is declared here and
# again in a second block below. BEAM will keep only one definition, silently
# losing indexing operations critical to the search subsystem.

defmodule Search.Indexer do
  @moduledoc """
  Manages Elasticsearch/OpenSearch document indexing operations.
  Defined in `lib/search/indexer.ex`.
  """

  alias Search.{ESClient, MappingRegistry, IndexPipeline, BulkBuffer}

  @default_refresh "wait_for"
  @bulk_batch_size 250

  @type index_name :: String.t()
  @type doc_id :: String.t()
  @type document :: map()

  @doc "Index a single document into the specified index."
  @spec index_document(index_name(), doc_id(), document()) ::
          :ok | {:error, String.t()}
  def index_document(index, id, document) when is_binary(index) and is_binary(id) do
    with {:ok, pipeline} <- IndexPipeline.fetch(index),
         {:ok, processed} <- IndexPipeline.run(pipeline, document) do
      path = "/#{index}/_doc/#{id}"
      params = %{refresh: @default_refresh}

      case ESClient.put(path, processed, params) do
        {:ok, %{status: s}} when s in 200..201 -> :ok
        {:ok, %{status: s, body: body}} -> {:error, "ES returned #{s}: #{inspect(body)}"}
        {:error, reason} -> {:error, "ES request failed: #{inspect(reason)}"}
      end
    end
  end

  @doc "Remove a document from an index."
  @spec delete_document(index_name(), doc_id()) :: :ok | {:error, String.t()}
  def delete_document(index, id) do
    path = "/#{index}/_doc/#{id}"

    case ESClient.delete(path, %{refresh: @default_refresh}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "Delete failed (#{s}): #{inspect(b)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Index a list of documents using the Bulk API for efficiency."
  @spec bulk_index(index_name(), [document()]) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def bulk_index(index, documents) when is_list(documents) do
    documents
    |> Enum.chunk_every(@bulk_batch_size)
    |> Enum.reduce({:ok, 0}, fn batch, acc ->
      case acc do
        {:ok, total} ->
          case send_bulk_batch(index, batch) do
            {:ok, count} -> {:ok, total + count}
            {:error, _} = err -> err
          end

        err ->
          err
      end
    end)
  end

  @doc "Re-index all documents in a collection by fetching from the source."
  @spec reindex_collection(index_name(), (-> {:ok, [document()]} | {:error, term()})) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def reindex_collection(index, source_fn) do
    with {:ok, documents} <- source_fn() do
      bulk_index(index, documents)
    else
      {:error, reason} -> {:error, "Source fetch failed: #{inspect(reason)}"}
    end
  end

  @doc "Return the current Elasticsearch mapping for an index."
  @spec mapping(index_name()) :: {:ok, map()} | {:error, String.t()}
  def mapping(index) do
    case ESClient.get("/#{index}/_mapping") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, "Index not found: #{index}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp send_bulk_batch(index, batch) do
    lines =
      Enum.flat_map(batch, fn doc ->
        id = Map.get(doc, :id, Map.get(doc, "id", generate_id()))
        [Jason.encode!(%{"index" => %{"_index" => index, "_id" => id}}), Jason.encode!(doc)]
      end)
      |> Enum.join("\n")

    body = lines <> "\n"

    case ESClient.post("/_bulk", body, %{refresh: @default_refresh}) do
      {:ok, %{status: 200, body: %{"errors" => false, "items" => items}}} ->
        {:ok, length(items)}

      {:ok, %{status: _, body: b}} ->
        {:error, "Bulk index failed: #{inspect(b)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end

# VALIDATION: SMELL END

# ── file: lib/search/indexer_settings.ex  (index settings management added
#    later; developer accidentally reused the parent module name) ─────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Search.Indexer` replaces the first in
# BEAM. `index_document/3`, `delete_document/2`, `bulk_index/2`,
# `reindex_collection/2`, and `mapping/1` all become permanently unreachable.

defmodule Search.Indexer do
  @moduledoc """
  Index settings management: create, update, and alias Elasticsearch indices.
  Was intended to be `Search.Indexer.Settings` but was accidentally given the
  same module name as the core indexer.
  """

  alias Search.ESClient

  @doc "Create a new index with the provided settings and mappings."
  @spec create_index(String.t(), map()) :: :ok | {:error, String.t()}
  def create_index(index, config) do
    case ESClient.put("/#{index}", config) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 400, body: %{"error" => %{"type" => "resource_already_exists_exception"}}}} ->
        {:error, "Index already exists: #{index}"}
      {:ok, %{status: s, body: b}} -> {:error, "Create failed (#{s}): #{inspect(b)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Update the dynamic settings of an existing index."
  @spec update_settings(String.t(), map()) :: :ok | {:error, String.t()}
  def update_settings(index, settings) do
    case ESClient.put("/#{index}/_settings", settings) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "Settings update failed (#{s}): #{inspect(b)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Add an alias pointing to a backing index."
  @spec add_alias(String.t(), String.t()) :: :ok | {:error, String.t()}
  def add_alias(index, alias_name) do
    body = %{actions: [%{add: %{index: index, alias: alias_name}}]}

    case ESClient.post("/_aliases", body) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "Alias add failed (#{s}): #{inspect(b)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Delete an existing index and all its documents."
  @spec delete_index(String.t()) :: :ok | {:error, String.t()}
  def delete_index(index) do
    case ESClient.delete("/#{index}") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, "Index not found: #{index}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end

# VALIDATION: SMELL END
```
