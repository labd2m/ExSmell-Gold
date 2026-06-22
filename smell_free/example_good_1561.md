```elixir
defmodule Search.Index.DocumentPipeline do
  @moduledoc """
  Processes raw documents through a multi-stage indexing pipeline.

  Each stage is independently composable. Stages normalize, enrich, and
  tokenize documents before they are submitted to the search backend.
  """

  alias Search.Index.{Normalizer, Enricher, Tokenizer, BackendClient}

  @type raw_document :: %{
          id: String.t(),
          body: String.t(),
          metadata: map()
        }

  @type indexed_document :: %{
          id: String.t(),
          tokens: [String.t()],
          fields: map(),
          language: String.t()
        }

  @type pipeline_error ::
          {:error, :normalization_failed, String.t()}
          | {:error, :enrichment_failed, String.t()}
          | {:error, :tokenization_failed, String.t()}
          | {:error, :index_failed, String.t()}

  @doc """
  Runs a single document through the full indexing pipeline.

  Returns `{:ok, indexed_document}` or a tagged error tuple indicating
  which pipeline stage failed.
  """
  @spec run(raw_document()) :: {:ok, indexed_document()} | pipeline_error()
  def run(%{id: _id, body: _body, metadata: _metadata} = document) do
    with {:ok, normalized} <- normalize(document),
         {:ok, enriched} <- enrich(normalized),
         {:ok, tokenized} <- tokenize(enriched),
         {:ok, submitted} <- submit(tokenized) do
      {:ok, submitted}
    end
  end

  @doc """
  Processes a batch of documents, returning successes and failures separately.
  """
  @spec run_batch([raw_document()]) :: %{succeeded: [indexed_document()], failed: [map()]}
  def run_batch(documents) when is_list(documents) do
    results = Enum.map(documents, fn doc -> {doc.id, run(doc)} end)

    Enum.reduce(results, %{succeeded: [], failed: []}, &collect_result/2)
  end

  defp normalize(document) do
    case Normalizer.normalize(document.body, document.metadata) do
      {:ok, normalized_body} ->
        {:ok, %{document | body: normalized_body}}

      {:error, reason} ->
        {:error, :normalization_failed, reason}
    end
  end

  defp enrich(document) do
    case Enricher.enrich(document.id, document.metadata) do
      {:ok, enriched_fields} ->
        merged_metadata = Map.merge(document.metadata, enriched_fields)
        {:ok, %{document | metadata: merged_metadata}}

      {:error, reason} ->
        {:error, :enrichment_failed, reason}
    end
  end

  defp tokenize(document) do
    language = Map.get(document.metadata, "language", "en")

    case Tokenizer.tokenize(document.body, language) do
      {:ok, tokens} ->
        indexed = %{
          id: document.id,
          tokens: tokens,
          fields: document.metadata,
          language: language
        }

        {:ok, indexed}

      {:error, reason} ->
        {:error, :tokenization_failed, reason}
    end
  end

  defp submit(indexed_document) do
    case BackendClient.index(indexed_document) do
      :ok -> {:ok, indexed_document}
      {:error, reason} -> {:error, :index_failed, reason}
    end
  end

  defp collect_result({_id, {:ok, doc}}, %{succeeded: succ} = acc) do
    %{acc | succeeded: [doc | succ]}
  end

  defp collect_result({id, {:error, stage, reason}}, %{failed: failed} = acc) do
    %{acc | failed: [%{id: id, stage: stage, reason: reason} | failed]}
  end
end
```
