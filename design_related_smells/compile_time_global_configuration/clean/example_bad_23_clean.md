```elixir
defmodule Search.ElasticsearchClient do
  @moduledoc """
  Client for indexing and querying documents in Elasticsearch.
  Index names are built by combining a configurable prefix with a
  document type suffix, allowing the same codebase to target different
  clusters (staging, production) without code changes.
  """

  require Logger

  @es_base_url Application.get_env(:search, :es_base_url, "http://localhost:9200")
  @request_timeout_ms 15_000
  @bulk_batch_size 250

  @index_prefix Application.fetch_env!(:search, :index_prefix)

  @type doc_id :: String.t()
  @type doc_type :: String.t()
  @type document :: map()
  @type search_query :: map()
  @type es_result :: {:ok, map()} | {:error, term()}

  @doc """
  Indexes a single document. Creates or replaces the document at `id`.

  ## Parameters
    - `type` - The document type used to select the index (e.g. `"products"`).
    - `id` - Unique document identifier.
    - `document` - Map of fields to index.
  """
  @spec index_document(doc_type(), doc_id(), document()) :: es_result()
  def index_document(type, id, document)
      when is_binary(type) and is_binary(id) and is_map(document) do
    index = build_index_name(type)
    url = "#{@es_base_url}/#{index}/_doc/#{URI.encode(id)}"
    Logger.info("Indexing document type=#{type} id=#{id} index=#{index}")
    put(url, document)
  end

  @doc """
  Executes a search query against the index for `type`.

  ## Parameters
    - `type` - Document type to search.
    - `query` - An Elasticsearch Query DSL map.
  """
  @spec search(doc_type(), search_query()) :: es_result()
  def search(type, query) when is_binary(type) and is_map(query) do
    index = build_index_name(type)
    url = "#{@es_base_url}/#{index}/_search"
    Logger.debug("Searching type=#{type} index=#{index}")
    post(url, query)
  end

  @doc """
  Deletes a document by `id` from the index for `type`.
  """
  @spec delete_document(doc_type(), doc_id()) :: es_result()
  def delete_document(type, id) when is_binary(type) and is_binary(id) do
    index = build_index_name(type)
    url = "#{@es_base_url}/#{index}/_doc/#{URI.encode(id)}"
    Logger.info("Deleting document type=#{type} id=#{id}")
    delete(url)
  end

  @doc """
  Indexes a list of documents using the Elasticsearch Bulk API.
  Automatically chunks `documents` into batches of #{@bulk_batch_size}.

  ## Parameters
    - `type` - Document type determining the target index.
    - `documents` - List of `{id, document}` tuples.
  """
  @spec bulk_index(doc_type(), [{doc_id(), document()}]) ::
          {:ok, %{indexed: non_neg_integer(), errors: non_neg_integer()}} | {:error, term()}
  def bulk_index(type, documents) when is_binary(type) and is_list(documents) do
    index = build_index_name(type)
    Logger.info("Bulk indexing type=#{type} count=#{length(documents)} index=#{index}")

    {indexed, errors} =
      documents
      |> Enum.chunk_every(@bulk_batch_size)
      |> Enum.reduce({0, 0}, fn batch, {acc_ok, acc_err} ->
        case send_bulk_batch(index, batch) do
          {:ok, %{"errors" => false, "items" => items}} ->
            {acc_ok + length(items), acc_err}

          {:ok, %{"items" => items}} ->
            ok_count = Enum.count(items, fn i -> get_in(i, ["index", "status"]) in 200..201 end)
            {acc_ok + ok_count, acc_err + (length(items) - ok_count)}

          {:error, _} ->
            {acc_ok, acc_err + length(batch)}
        end
      end)

    {:ok, %{indexed: indexed, errors: errors}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_index_name(type), do: "#{@index_prefix}_#{type}"

  defp send_bulk_batch(index, pairs) do
    url = "#{@es_base_url}/#{index}/_bulk"

    ndjson =
      pairs
      |> Enum.flat_map(fn {id, doc} ->
        [
          Jason.encode!(%{"index" => %{"_id" => id}}) <> "\n",
          Jason.encode!(doc) <> "\n"
        ]
      end)
      |> Enum.join()

    headers = [{"Content-Type", "application/x-ndjson"}]

    case HTTPoison.post(url, ndjson, headers, recv_timeout: @request_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..201 ->
        {:ok, Jason.decode!(body)}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        Logger.error("ES bulk error status=#{code} body=#{String.slice(body, 0, 200)}")
        {:error, {:http_error, code}}

      {:error, reason} ->
        Logger.error("ES bulk request failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp put(url, body), do: request(:put, url, body)
  defp post(url, body), do: request(:post, url, body)

  defp delete(url) do
    case HTTPoison.delete(url, json_headers(), recv_timeout: @request_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: code}} when code in [200, 204] -> {:ok, %{}}
      {:ok, %HTTPoison.Response{status_code: 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, url, body) do
    encoded = Jason.encode!(body)
    fun = if method == :put, do: &HTTPoison.put/4, else: &HTTPoison.post/4

    case fun.(url, encoded, json_headers(), recv_timeout: @request_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: code, body: resp}} when code in 200..201 ->
        {:ok, Jason.decode!(resp)}

      {:ok, %HTTPoison.Response{status_code: code, body: resp}} ->
        Logger.error("ES request failed url=#{url} status=#{code}")
        {:error, {:http_error, code, Jason.decode!(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp json_headers, do: [{"Content-Type", "application/json"}]
end
```
