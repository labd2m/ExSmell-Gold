```elixir
defmodule Search.IndexRouter do
  @moduledoc """
  Routes search and indexing operations to the correct Elasticsearch index
  based on the current tenant context in a multi-tenant SaaS environment.
  """

  require Logger

  alias Search.{ElasticsearchClient, TenantContext, DocumentSerializer}

  @index_suffix "_documents"
  @default_shards 2
  @default_replicas 1

  @spec index_document(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def index_document(%{tenant_slug: tenant_slug} = _tenant, document) do
    with {:ok, index_name} <- build_index_name(tenant_slug),
         :ok <- ensure_index_exists(index_name),
         {:ok, serialized} <- DocumentSerializer.serialize(document),
         {:ok, doc_id} <- ElasticsearchClient.index(index_name, serialized) do
      Logger.debug("Document indexed", index: index_name, doc_id: doc_id)
      {:ok, doc_id}
    end
  end

  @spec search(map(), String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def search(%{tenant_slug: tenant_slug} = _tenant, query_string, opts \\ %{}) do
    with {:ok, index_name} <- build_index_name(tenant_slug),
         {:ok, raw_results} <-
           ElasticsearchClient.search(index_name, %{
             query: %{match: %{_all: query_string}},
             size: Map.get(opts, :limit, 20),
             from: Map.get(opts, :offset, 0)
           }) do
      hits = extract_hits(raw_results)
      {:ok, hits}
    end
  end

  @spec delete_document(map(), String.t()) :: :ok | {:error, term()}
  def delete_document(%{tenant_slug: tenant_slug}, doc_id) do
    with {:ok, index_name} <- build_index_name(tenant_slug) do
      ElasticsearchClient.delete(index_name, doc_id)
    end
  end

  @spec create_tenant_index(map()) :: :ok | {:error, term()}
  def create_tenant_index(%{tenant_slug: tenant_slug}) do
    with {:ok, index_name} <- build_index_name(tenant_slug) do
      settings = %{
        number_of_shards: @default_shards,
        number_of_replicas: @default_replicas
      }

      ElasticsearchClient.create_index(index_name, settings)
    end
  end

  defp build_index_name(tenant_slug) when is_binary(tenant_slug) do
    index_string = "#{tenant_slug}#{@index_suffix}"
    {:ok, String.to_atom(index_string)}
  end

  defp build_index_name(_), do: {:error, :invalid_tenant_slug}

  defp ensure_index_exists(index_name) do
    index_str = Atom.to_string(index_name)

    case ElasticsearchClient.index_exists?(index_str) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        Logger.info("Creating missing index", index: index_str)

        ElasticsearchClient.create_index(index_str, %{
          number_of_shards: @default_shards,
          number_of_replicas: @default_replicas
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_hits(%{"hits" => %{"hits" => hits}}) do
    Enum.map(hits, fn hit ->
      Map.merge(hit["_source"], %{"_id" => hit["_id"], "_score" => hit["_score"]})
    end)
  end

  defp extract_hits(_), do: []
end
```
