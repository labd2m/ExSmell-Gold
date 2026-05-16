```elixir
defmodule MyApp.Search.Indexer do
  @moduledoc """
  Manages the indexing lifecycle for searchable documents across product,
  article, and user content types. Integrates with an external search backend
  (e.g. Elasticsearch) for real-time indexing and re-indexing workflows.
  """

  alias MyApp.Search.Backend
  alias MyApp.Search.Schema
  alias MyApp.Search.IndexResult
  alias MyApp.Search.RateLimiter

  @supported_types [:product, :article, :user_profile, :support_ticket]
  @default_index "default"

  defstruct [
    :id, :doc_type, :doc_id,
    :index_name, :indexed_at,
    :took_ms, :backend_id
  ]

  def build_doc(doc_type, source, opts \\ []) do
    index = Keyword.get(opts, :index, @default_index)

    %{
      doc_type: doc_type,
      doc_id: source.id,
      index: index,
      body: Schema.transform(doc_type, source),
      source: source
    }
  end

  def index_document(doc, opts \\ []) when is_list(opts) do
    on_success = Keyword.get(opts, :on_success, :ok)
    refresh = Keyword.get(opts, :refresh, :false)
    pipeline = Keyword.get(opts, :pipeline)

    unless doc.doc_type in @supported_types do
      raise ArgumentError, "unsupported doc type: #{inspect(doc.doc_type)}"
    end

    with :ok <- RateLimiter.check(:index),
         :ok <- Schema.validate(doc.doc_type, doc.body) do
      request = %{
        index: doc.index,
        id: "#{doc.doc_type}_#{doc.doc_id}",
        body: doc.body,
        refresh: refresh,
        pipeline: pipeline
      }

      start = System.monotonic_time(:millisecond)

      case Backend.index(request) do
        {:ok, backend_response} ->
          took_ms = System.monotonic_time(:millisecond) - start

          case on_success do
            :ok ->
              :ok

            :id ->
              {:ok, backend_response.id}

            :result ->
              result = %__MODULE__{
                id: generate_id(),
                doc_type: doc.doc_type,
                doc_id: doc.doc_id,
                index_name: doc.index,
                indexed_at: DateTime.utc_now(),
                took_ms: took_ms,
                backend_id: backend_response.id
              }

              {:ok, result}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def bulk_index(docs, opts \\ []) do
    Enum.reduce_while(docs, {:ok, []}, fn doc, {:ok, acc} ->
      case index_document(doc, Keyword.put(opts, :on_success, :id)) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def delete_document(doc_type, doc_id, index \\ @default_index) do
    Backend.delete(index, "#{doc_type}_#{doc_id}")
  end

  def reindex(doc_type, opts \\ []) do
    index = Keyword.get(opts, :index, @default_index)
    Backend.reindex(doc_type, index)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
