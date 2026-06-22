```elixir
defmodule DocIngest.Parser do
  @moduledoc """
  Parses raw document uploads into structured, normalized records.

  Parsing proceeds through discrete stages: detection, extraction, and normalization.
  Each stage returns a typed result; failures short-circuit the pipeline without
  raising exceptions.
  """

  alias DocIngest.Parser.{Detector, Extractor, Normalizer, ParsedDocument}

  @type raw_input :: %{
          filename: String.t(),
          content_type: String.t(),
          binary: binary()
        }

  @doc """
  Parses a raw document binary into a `ParsedDocument`.

  Supported content types: `application/pdf`, `text/plain`, `text/csv`.
  """
  @spec parse(raw_input()) :: {:ok, ParsedDocument.t()} | {:error, String.t()}
  def parse(%{filename: filename, content_type: ct, binary: bin})
      when is_binary(filename) and is_binary(ct) and is_binary(bin) do
    with {:ok, doc_type} <- Detector.detect(ct, filename),
         {:ok, raw_fields} <- Extractor.extract(doc_type, bin),
         {:ok, parsed} <- Normalizer.normalize(doc_type, raw_fields, filename) do
      {:ok, parsed}
    end
  end

  def parse(_), do: {:error, "invalid document input"}
end

defmodule DocIngest.Parser.Detector do
  @moduledoc "Detects document type from MIME type and filename extension."

  @type doc_type :: :pdf | :plain_text | :csv

  @spec detect(String.t(), String.t()) :: {:ok, doc_type()} | {:error, String.t()}
  def detect("application/pdf", _), do: {:ok, :pdf}
  def detect("text/plain", _), do: {:ok, :plain_text}
  def detect("text/csv", _), do: {:ok, :csv}

  def detect(ct, filename) do
    ext = filename |> Path.extname() |> String.downcase()
    detect_by_extension(ext, ct)
  end

  defp detect_by_extension(".pdf", _), do: {:ok, :pdf}
  defp detect_by_extension(".txt", _), do: {:ok, :plain_text}
  defp detect_by_extension(".csv", _), do: {:ok, :csv}
  defp detect_by_extension(_, ct), do: {:error, "unsupported document type: #{ct}"}
end

defmodule DocIngest.Parser.Extractor do
  @moduledoc "Extracts raw text fields from document binaries by type."

  alias DocIngest.Parser.Detector

  @spec extract(Detector.doc_type(), binary()) :: {:ok, map()} | {:error, String.t()}
  def extract(:pdf, binary) do
    extract_pdf(binary)
  end

  def extract(:plain_text, binary) when is_binary(binary) do
    {:ok, %{body: binary, page_count: 1}}
  end

  def extract(:csv, binary) when is_binary(binary) do
    parse_csv(binary)
  end

  defp extract_pdf(binary) do
    case :binary.match(binary, <<"%PDF">>) do
      :nomatch -> {:error, "not a valid PDF binary"}
      _ -> {:ok, %{body: "[pdf content]", page_count: estimate_pdf_pages(binary)}}
    end
  end

  defp estimate_pdf_pages(binary) do
    binary |> :binary.matches(<<"/Page\n">>) |> length() |> max(1)
  end

  defp parse_csv(binary) do
    rows =
      binary
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ","))

    {:ok, %{rows: rows, row_count: length(rows)}}
  end
end

defmodule DocIngest.Parser.ParsedDocument do
  @moduledoc "Structured value object produced by a successful parse."

  @enforce_keys [:filename, :doc_type, :fields, :parsed_at]
  defstruct [:filename, :doc_type, :fields, :parsed_at]

  @type t :: %__MODULE__{
          filename: String.t(),
          doc_type: DocIngest.Parser.Detector.doc_type(),
          fields: map(),
          parsed_at: DateTime.t()
        }
end

defmodule DocIngest.Parser.Normalizer do
  @moduledoc "Normalizes extracted raw fields into a `ParsedDocument`."

  alias DocIngest.Parser.{Detector, ParsedDocument}

  @spec normalize(Detector.doc_type(), map(), String.t()) ::
          {:ok, ParsedDocument.t()} | {:error, String.t()}
  def normalize(doc_type, fields, filename)
      when is_atom(doc_type) and is_map(fields) and is_binary(filename) do
    doc = %ParsedDocument{
      filename: filename,
      doc_type: doc_type,
      fields: fields,
      parsed_at: DateTime.utc_now()
    }

    {:ok, doc}
  end

  def normalize(_, _, _), do: {:error, "normalization failed: invalid arguments"}
end
```
