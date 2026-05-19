# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `DocumentProcessing.OCRCoordinator.dispatch_for_extraction/2` |
| **Affected function(s)** | `dispatch_for_extraction/2` |
| **Short explanation** | The OCR coordinator builds a batch of fully parsed document records—each containing all raw page text, positional bounding-box data, and image metadata—and sends the complete batch to an entity-extraction worker process in one message. The batch is very large, causing a prolonged sender-blocking deep-copy. |

```elixir
defmodule DocumentProcessing.BoundingBox do
  defstruct [:x, :y, :width, :height, :confidence]

  @type t :: %__MODULE__{
          x: float(),
          y: float(),
          width: float(),
          height: float(),
          confidence: float()
        }
end

defmodule DocumentProcessing.Word do
  defstruct [:text, :bounding_box, :font_size, :bold, :italic]

  @type t :: %__MODULE__{
          text: String.t(),
          bounding_box: DocumentProcessing.BoundingBox.t(),
          font_size: float() | nil,
          bold: boolean(),
          italic: boolean()
        }
end

defmodule DocumentProcessing.PageBlock do
  defstruct [:block_type, :words, :bounding_box, :reading_order]

  @type t :: %__MODULE__{
          block_type: :paragraph | :heading | :table | :list | :figure_caption,
          words: [DocumentProcessing.Word.t()],
          bounding_box: DocumentProcessing.BoundingBox.t(),
          reading_order: non_neg_integer()
        }
end

defmodule DocumentProcessing.Page do
  @enforce_keys [:page_number, :blocks, :width_px, :height_px]
  defstruct [:page_number, :blocks, :width_px, :height_px, :image_dpi, :rotation_degrees]

  @type t :: %__MODULE__{
          page_number: pos_integer(),
          blocks: [DocumentProcessing.PageBlock.t()],
          width_px: pos_integer(),
          height_px: pos_integer(),
          image_dpi: pos_integer(),
          rotation_degrees: float()
        }
end

defmodule DocumentProcessing.Document do
  @enforce_keys [:id, :filename, :pages, :mime_type, :uploaded_at]
  defstruct [
    :id,
    :filename,
    :pages,
    :mime_type,
    :uploaded_at,
    :language,
    :author,
    :source_system,
    :metadata
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          filename: String.t(),
          pages: [DocumentProcessing.Page.t()],
          mime_type: String.t(),
          uploaded_at: DateTime.t(),
          language: String.t(),
          author: String.t() | nil,
          source_system: String.t(),
          metadata: map()
        }
end

defmodule DocumentProcessing.OCREngine do
  @moduledoc "Simulates OCR processing of uploaded documents."

  @spec process_batch([String.t()]) :: [DocumentProcessing.Document.t()]
  def process_batch(document_ids) do
    now = DateTime.utc_now()

    Enum.map(document_ids, fn doc_id ->
      pages =
        Enum.map(1..25, fn page_num ->
          blocks =
            Enum.map(1..15, fn block_n ->
              words =
                Enum.map(1..40, fn word_n ->
                  %DocumentProcessing.Word{
                    text: "word_#{rem(doc_id |> String.length() * word_n, 5000)}",
                    bold: rem(word_n, 10) == 0,
                    italic: rem(word_n, 15) == 0,
                    font_size: 8.0 + :rand.uniform() * 16,
                    bounding_box: %DocumentProcessing.BoundingBox{
                      x: :rand.uniform() * 600,
                      y: :rand.uniform() * 800,
                      width: 20.0 + :rand.uniform() * 80,
                      height: 10.0 + :rand.uniform() * 20,
                      confidence: 0.8 + :rand.uniform() * 0.2
                    }
                  }
                end)

              %DocumentProcessing.PageBlock{
                block_type: Enum.random([:paragraph, :heading, :table, :list]),
                words: words,
                reading_order: block_n,
                bounding_box: %DocumentProcessing.BoundingBox{
                  x: :rand.uniform() * 100,
                  y: :rand.uniform() * 700,
                  width: 500.0,
                  height: 40.0 + :rand.uniform() * 200,
                  confidence: 0.95
                }
              }
            end)

          %DocumentProcessing.Page{
            page_number: page_num,
            blocks: blocks,
            width_px: 2480,
            height_px: 3508,
            image_dpi: 300,
            rotation_degrees: 0.0
          }
        end)

      %DocumentProcessing.Document{
        id: doc_id,
        filename: "document_#{doc_id}.pdf",
        pages: pages,
        mime_type: "application/pdf",
        uploaded_at: DateTime.add(now, -:rand.uniform(86_400), :second),
        language: Enum.random(["en", "pt", "de", "fr", "es"]),
        author: "Author #{:rand.uniform(1000)}",
        source_system: Enum.random(["email_ingest", "web_upload", "sftp_drop"]),
        metadata: %{
          page_count: 25,
          file_size_bytes: :rand.uniform(10_000_000),
          ocr_engine: "Tesseract 5.3",
          processing_time_ms: :rand.uniform(5000)
        }
      }
    end)
  end
end

defmodule DocumentProcessing.ExtractionWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:extract_entities, batch_id, documents}, _state) do
    {:noreply, {batch_id, length(documents)}}
  end
end

defmodule DocumentProcessing.OCRCoordinator do
  @moduledoc """
  Processes a batch of documents through the OCR engine and sends the
  full OCR output to the entity extraction worker.
  """

  require Logger

  @spec dispatch_for_extraction(pid(), [String.t()]) :: :ok
  def dispatch_for_extraction(extraction_pid, document_ids) do
    batch_id = "batch_#{:rand.uniform(999_999)}"

    Logger.info("Running OCR on batch #{batch_id} (#{length(document_ids)} documents)...")

    documents = DocumentProcessing.OCREngine.process_batch(document_ids)

    Logger.info(
      "OCR complete for batch #{batch_id}. Dispatching #{length(documents)} documents to extractor..."
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `documents` is a list of Document
    # structs, each containing 25 Pages, each with 15 PageBlocks, each with
    # 40 Word structs (plus BoundingBox sub-structs). The total structure size
    # is enormous. Sending this in one process message causes a massive heap-to-
    # heap copy that blocks the OCRCoordinator process for a long time, stalling
    # the entire document processing pipeline.
    send(extraction_pid, {:extract_entities, batch_id, documents})
    # VALIDATION: SMELL END

    Logger.info("Batch #{batch_id} dispatched for entity extraction.")
    :ok
  end
end
```
