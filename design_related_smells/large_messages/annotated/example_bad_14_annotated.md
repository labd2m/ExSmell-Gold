# Annotated Example 14 — Large Messages

| Field                  | Value                                                                        |
|------------------------|------------------------------------------------------------------------------|
| **Smell name**         | Large messages                                                               |
| **Expected location**  | `Search.IndexingPipeline.reindex/2`                                         |
| **Affected function(s)**| `reindex/2`, `handle_cast/2` (GenServer)                                   |
| **Explanation**        | The indexing pipeline fetches a full corpus of documents — each including large text body fields, embedding vectors, and nested metadata — and sends the entire corpus to the `Indexer` GenServer in one `GenServer.cast`. Text corpora are particularly expensive to copy between processes because of the binary data involved. A corpus of 10 000 documents with substantial body text can easily represent tens of megabytes, and copying this in a single message blocks the pipeline process measurably. |

```elixir
defmodule Search.EmbeddingVector do
  @moduledoc "Dense vector representation of a document."
  defstruct [:dimensions, :values, :model_version]
end

defmodule Search.DocumentMetadata do
  defstruct [
    :author_id,
    :tags,
    :category,
    :language,
    :published_at,
    :last_modified_at,
    :word_count,
    :read_time_minutes,
    :access_level,
    :source_url
  ]
end

defmodule Search.Document do
  @enforce_keys [:id, :title, :body]
  defstruct [
    :id,
    :title,
    :body,
    :summary,
    :embedding,
    :metadata,
    :boost_score,
    :checksums
  ]
end

defmodule Search.CorpusLoader do
  @moduledoc "Simulates loading a document corpus from a content management system."

  @spec load(String.t(), non_neg_integer()) :: list(Search.Document.t())
  def load(corpus_id, limit) do
    Enum.map(1..limit, fn i ->
      body = Enum.map_join(1..200, " ", fn j -> "word#{rem(j + i, 5_000)}" end)

      %Search.Document{
        id: "DOC-#{corpus_id}-#{i}",
        title: "Document #{i} in corpus #{corpus_id}",
        body: body,
        summary: "Summary of document #{i}: " <> String.slice(body, 0, 150),
        embedding: %Search.EmbeddingVector{
          dimensions: 768,
          values: Enum.map(1..768, fn _ -> :rand.uniform() * 2.0 - 1.0 end),
          model_version: "text-embedding-3-large"
        },
        metadata: %Search.DocumentMetadata{
          author_id: "AUTH-#{rem(i, 500)}",
          tags: Enum.map(1..5, fn j -> "tag-#{rem(i + j, 100)}" end),
          category: Enum.random(["tech", "legal", "finance", "hr", "product"]),
          language: "pt-BR",
          published_at: DateTime.utc_now() |> DateTime.add(-rem(i, 365) * 86_400),
          last_modified_at: DateTime.utc_now(),
          word_count: 200,
          read_time_minutes: 1,
          access_level: Enum.random([:public, :internal, :restricted]),
          source_url: "https://cms.internal/doc/#{i}"
        },
        boost_score: :rand.uniform(),
        checksums: %{
          body_sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
          doc_etag: "etag-#{i}"
        }
      }
    end)
  end
end

defmodule Search.Indexer do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{index: %{}, last_indexed_at: nil}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:index_documents, corpus_id, documents}, state) do
    new_entries =
      Map.new(documents, fn doc ->
        {doc.id, %{title: doc.title, boost: doc.boost_score, corpus: corpus_id}}
      end)

    updated_index = Map.merge(state.index, new_entries)
    {:noreply, %{state | index: updated_index, last_indexed_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{document_count: map_size(state.index)}, state}
  end
end

defmodule Search.IndexingPipeline do
  @moduledoc "Orchestrates full and incremental corpus re-indexing."

  require Logger

  @default_batch_size 10_000

  @spec reindex(pid(), String.t()) :: :ok
  def reindex(indexer_pid, corpus_id) do
    Logger.info("Starting full re-index for corpus #{corpus_id}")

    documents = Search.CorpusLoader.load(corpus_id, @default_batch_size)

    Logger.info(
      "Loaded #{length(documents)} documents — dispatching to indexer (corpus: #{corpus_id})"
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `documents` is a list of 10 000
    # Document structs, each containing: a large body binary (~1 400 chars),
    # an EmbeddingVector struct holding a 768-element float list, a
    # DocumentMetadata struct with 5 tags, and a checksums map with a SHA-256
    # hex binary. The embedding vectors alone represent 768 floats × 10 000
    # documents = 7.68 million floats. Casting all of this in one message
    # produces a very large heap copy, blocking the pipeline process for a
    # significant duration and potentially causing the Indexer's mailbox to
    # accumulate faster than it can drain if multiple corpora are reindexed
    # concurrently.
    GenServer.cast(indexer_pid, {:index_documents, corpus_id, documents})
    # VALIDATION: SMELL END

    :ok
  end
end
```
