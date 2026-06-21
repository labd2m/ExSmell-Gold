```elixir
defmodule Search.IndexWorker do
  @moduledoc """
  An Oban worker responsible for keeping the Elasticsearch index in sync
  with the primary database. Handles three operations — `:index`, `:update`,
  and `:delete` — dispatched by domain contexts after any mutation.
  Bulk indexing operations are batched within the worker to reduce the
  number of round-trips to the search cluster.
  """

  use Oban.Worker,
    queue: :search_indexing,
    max_attempts: 5,
    unique: [period: 10, fields: [:args]]

  alias Search.{DocumentBuilder, ElasticsearchClient}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation" => "index", "entity_type" => type, "entity_id" => id}}) do
    with {:ok, entity} <- load_entity(type, id),
         {:ok, document} <- DocumentBuilder.build(entity),
         {:ok, _response} <- ElasticsearchClient.index(index_for(type), id, document) do
      Logger.debug("Entity indexed", entity_type: type, entity_id: id)
      :ok
    end
  end

  def perform(%Oban.Job{args: %{"operation" => "update", "entity_type" => type, "entity_id" => id, "fields" => fields}}) do
    with {:ok, entity} <- load_entity(type, id),
         {:ok, partial} <- DocumentBuilder.build_partial(entity, fields),
         {:ok, _response} <- ElasticsearchClient.update(index_for(type), id, partial) do
      Logger.debug("Entity updated in index", entity_type: type, entity_id: id)
      :ok
    end
  end

  def perform(%Oban.Job{args: %{"operation" => "delete", "entity_type" => type, "entity_id" => id}}) do
    case ElasticsearchClient.delete(index_for(type), id) do
      {:ok, _} ->
        Logger.debug("Entity deleted from index", entity_type: type, entity_id: id)
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("Unknown indexing operation", args: args)
    {:error, :unknown_operation}
  end

  # ---------------------------------------------------------------------------
  # Dispatch helpers (called from domain contexts)
  # ---------------------------------------------------------------------------

  @doc """
  Enqueues an index job for the given entity. Call after a successful insert.
  """
  @spec enqueue_index(binary(), binary()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_index(entity_type, entity_id) when is_binary(entity_type) and is_binary(entity_id) do
    %{"operation" => "index", "entity_type" => entity_type, "entity_id" => entity_id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Enqueues a partial update job for the specified fields only.
  """
  @spec enqueue_update(binary(), binary(), [binary()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_update(entity_type, entity_id, fields)
      when is_binary(entity_type) and is_binary(entity_id) and is_list(fields) do
    %{
      "operation" => "update",
      "entity_type" => entity_type,
      "entity_id" => entity_id,
      "fields" => fields
    }
    |> new()
    |> Oban.insert()
  end

  @doc """
  Enqueues a delete job. Safe to call even when the document may not exist.
  """
  @spec enqueue_delete(binary(), binary()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_delete(entity_type, entity_id) when is_binary(entity_type) and is_binary(entity_id) do
    %{"operation" => "delete", "entity_type" => entity_type, "entity_id" => entity_id}
    |> new()
    |> Oban.insert()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_entity("product", id), do: Catalog.Products.fetch(id)
  defp load_entity("article", id), do: Content.Articles.fetch(id)
  defp load_entity("user", id), do: Accounts.Users.fetch(id)
  defp load_entity(type, _id), do: {:error, {:unknown_entity_type, type}}

  defp index_for("product"), do: "products"
  defp index_for("article"), do: "articles"
  defp index_for("user"), do: "users"
  defp index_for(type), do: type
end
```
