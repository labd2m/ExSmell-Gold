# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Search.IndexBuilder.submit_index_to_writer/2` |
| **Affected function(s)** | `submit_index_to_writer/2` |
| **Short explanation** | The index builder computes a full inverted index from the document corpus in memory and then sends the entire index data structure—potentially millions of posting-list entries—to a persistent writer process in one message, causing a very large and blocking deep-copy. |

```elixir
defmodule Search.TokenPosition do
  defstruct [:offset, :field, :frequency]

  @type t :: %__MODULE__{
          offset: non_neg_integer(),
          field: String.t(),
          frequency: pos_integer()
        }
end

defmodule Search.Posting do
  @enforce_keys [:doc_id, :score, :positions]
  defstruct [:doc_id, :score, :positions, :field_lengths]

  @type t :: %__MODULE__{
          doc_id: String.t(),
          score: float(),
          positions: [Search.TokenPosition.t()],
          field_lengths: %{String.t() => non_neg_integer()}
        }
end

defmodule Search.PostingList do
  @enforce_keys [:term, :doc_frequency, :postings]
  defstruct [:term, :doc_frequency, :postings, :total_term_frequency, :idf]

  @type t :: %__MODULE__{
          term: String.t(),
          doc_frequency: pos_integer(),
          postings: [Search.Posting.t()],
          total_term_frequency: pos_integer(),
          idf: float()
        }
end

defmodule Search.CorpusDoc do
  @enforce_keys [:id, :title, :body, :tags]
  defstruct [:id, :title, :body, :tags, :author, :published_at, :url]
end

defmodule Search.Corpus do
  @moduledoc "Returns the set of documents to be indexed."

  @spec load :: [Search.CorpusDoc.t()]
  def load do
    now = DateTime.utc_now()

    Enum.map(1..20_000, fn n ->
      %Search.CorpusDoc{
        id: "doc_#{n}",
        title: "Article #{n}: #{Enum.random(["Guide", "Tutorial", "Overview", "Reference"])} on Topic #{rem(n, 200) + 1}",
        body:
          "Introduction to topic #{rem(n, 200) + 1}. " <>
            String.duplicate(
              "This document covers important aspects of the subject matter in detail. " <>
                "Readers will learn about key concepts, best practices, and common pitfalls. ",
              20
            ),
        tags: Enum.map(1..5, fn t -> "tag_#{rem(n * t, 100) + 1}" end),
        author: "Author #{rem(n, 500) + 1}",
        published_at: DateTime.add(now, -:rand.uniform(365 * 5) * 86_400, :second),
        url: "https://docs.example.com/articles/#{n}"
      }
    end)
  end
end

defmodule Search.IndexBuilder do
  @moduledoc """
  Builds an in-memory inverted index from the document corpus and
  sends it to the index writer process for persistence.
  """

  require Logger

  @spec build_inverted_index([Search.CorpusDoc.t()]) :: %{String.t() => Search.PostingList.t()}
  def build_inverted_index(docs) do
    Logger.debug("Building inverted index for #{length(docs)} documents...")

    index =
      Enum.reduce(docs, %{}, fn doc, acc ->
        tokens =
          (doc.title <> " " <> doc.body)
          |> String.downcase()
          |> String.split(~r/\W+/, trim: true)
          |> Enum.frequencies()

        Enum.reduce(tokens, acc, fn {term, freq}, inner_acc ->
          posting = %Search.Posting{
            doc_id: doc.id,
            score: :math.log(1 + freq),
            positions:
              Enum.map(1..min(freq, 5), fn pos ->
                %Search.TokenPosition{
                  offset: pos * 10,
                  field: if(String.contains?(doc.title, term), do: "title", else: "body"),
                  frequency: freq
                }
              end),
            field_lengths: %{
              "title" => String.split(doc.title) |> length(),
              "body" => String.split(doc.body) |> length()
            }
          }

          Map.update(inner_acc, term, %Search.PostingList{
            term: term,
            doc_frequency: 1,
            total_term_frequency: freq,
            idf: 1.0,
            postings: [posting]
          }, fn existing ->
            %{existing |
              doc_frequency: existing.doc_frequency + 1,
              total_term_frequency: existing.total_term_frequency + freq,
              postings: [posting | existing.postings]
            }
          end)
        end)
      end)

    total_docs = length(docs)

    Map.new(index, fn {term, pl} ->
      idf = :math.log(total_docs / (1 + pl.doc_frequency))
      {term, %{pl | idf: idf}}
    end)
  end

  @spec submit_index_to_writer(pid(), String.t()) :: :ok
  def submit_index_to_writer(writer_pid, index_name) do
    Logger.info("Loading corpus for index '#{index_name}'...")

    docs = Search.Corpus.load()
    index = build_inverted_index(docs)

    Logger.info(
      "Built index '#{index_name}': #{map_size(index)} unique terms. Submitting to writer..."
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `index` is a map that may contain
    # tens of thousands of PostingList structs, each holding lists of Posting
    # structs (with TokenPosition sub-lists and field-length maps). In
    # aggregate this structure can be many hundreds of megabytes. Sending it
    # as a single process message forces the BEAM to deep-copy every byte to
    # the writer's heap, blocking the IndexBuilder process for a long time
    # and potentially crashing the system under memory pressure.
    send(writer_pid, {:write_index, index_name, index})
    # VALIDATION: SMELL END

    Logger.info("Index '#{index_name}' submitted to writer.")
    :ok
  end
end

defmodule Search.IndexWriterWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:write_index, name, index}, state) do
    {:noreply, Map.put(state, name, map_size(index))}
  end
end
```
