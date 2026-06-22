```elixir
defmodule Search.TenantIndexManager do
  @moduledoc """
  Manages per-tenant Elasticsearch index namespaces, ensuring that queries
  and writes never cross tenant boundaries. Index names are derived from a
  stable hash of the tenant ID so they are safe for use as Elasticsearch
  index names regardless of subdomain format. Index creation, mapping
  updates, and document operations all route through this module, which
  injects the correct index name automatically.
  """

  alias Search.ElasticsearchClient

  require Logger

  @type tenant_id :: binary()
  @type document_id :: binary()
  @type index_alias :: binary()

  @index_settings %{
    number_of_shards: 2,
    number_of_replicas: 1,
    analysis: %{
      analyzer: %{
        default: %{type: "standard"}
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Index management
  # ---------------------------------------------------------------------------

  @doc """
  Creates the Elasticsearch index for `tenant_id` with the configured
  mapping and settings. Safe to call multiple times; returns `:ok` if the
  index already exists.
  """
  @spec provision_index(tenant_id(), map()) :: :ok | {:error, term()}
  def provision_index(tenant_id, mapping \\ %{}) when is_binary(tenant_id) do
    index = index_name(tenant_id)
    body = %{settings: @index_settings, mappings: mapping}

    case ElasticsearchClient.create_index(index, body) do
      {:ok, _} ->
        Logger.info("Search index provisioned", tenant_id: tenant_id, index: index)
        :ok

      {:error, %{reason: "resource_already_exists_exception"}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to provision search index",
          tenant_id: tenant_id, index: index, reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Updates the mapping for an existing tenant index. Only additive changes
  are accepted; field type changes require re-indexing.
  """
  @spec update_mapping(tenant_id(), map()) :: :ok | {:error, term()}
  def update_mapping(tenant_id, mapping) when is_binary(tenant_id) and is_map(mapping) do
    index = index_name(tenant_id)

    case ElasticsearchClient.put_mapping(index, mapping) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes the index for `tenant_id`. Irreversible — used during tenant
  deprovisioning or full re-index workflows.
  """
  @spec delete_index(tenant_id()) :: :ok | {:error, :not_found | term()}
  def delete_index(tenant_id) when is_binary(tenant_id) do
    index = index_name(tenant_id)

    case ElasticsearchClient.delete_index(index) do
      {:ok, _} ->
        Logger.info("Search index deleted", tenant_id: tenant_id, index: index)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Document operations
  # ---------------------------------------------------------------------------

  @doc """
  Indexes `document` under `document_id` within the tenant's index.
  """
  @spec index_document(tenant_id(), document_id(), map()) :: {:ok, map()} | {:error, term()}
  def index_document(tenant_id, doc_id, document)
      when is_binary(tenant_id) and is_binary(doc_id) and is_map(document) do
    index = index_name(tenant_id)
    ElasticsearchClient.index(index, doc_id, document)
  end

  @doc """
  Removes a document from the tenant's index.
  """
  @spec delete_document(tenant_id(), document_id()) :: :ok | {:error, term()}
  def delete_document(tenant_id, doc_id) when is_binary(tenant_id) and is_binary(doc_id) do
    index = index_name(tenant_id)

    case ElasticsearchClient.delete(index, doc_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Executes a search query scoped to `tenant_id`'s index.
  Returns `{:ok, hits}` or `{:error, reason}`.
  """
  @spec search(tenant_id(), map()) :: {:ok, [map()]} | {:error, term()}
  def search(tenant_id, query) when is_binary(tenant_id) and is_map(query) do
    index = index_name(tenant_id)

    case ElasticsearchClient.search(index, query) do
      {:ok, %{hits: %{hits: hits}}} -> {:ok, hits}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Bulk indexes multiple documents for a tenant in a single request.
  Returns `{:ok, %{indexed: count, failed: count}}`.
  """
  @spec bulk_index(tenant_id(), [{document_id(), map()}]) ::
          {:ok, %{indexed: non_neg_integer(), failed: non_neg_integer()}} | {:error, term()}
  def bulk_index(tenant_id, documents)
      when is_binary(tenant_id) and is_list(documents) do
    index = index_name(tenant_id)

    operations =
      Enum.flat_map(documents, fn {doc_id, doc} ->
        [%{index: %{_index: index, _id: doc_id}}, doc]
      end)

    case ElasticsearchClient.bulk(operations) do
      {:ok, response} ->
        indexed = Enum.count(response["items"] || [], &(get_in(&1, ["index", "result"]) in ["created", "updated"]))
        failed = length(response["items"] || []) - indexed
        {:ok, %{indexed: indexed, failed: failed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns the Elasticsearch index name for `tenant_id`.
  """
  @spec index_name(tenant_id()) :: binary()
  def index_name(tenant_id) when is_binary(tenant_id) do
    hash =
      :crypto.hash(:sha256, tenant_id)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    env = Application.get_env(:my_app, :env, :prod)
    "#{env}_tenant_#{hash}"
  end
end
```
