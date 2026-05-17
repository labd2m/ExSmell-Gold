```elixir
defmodule Reporting.CsvRowExtractor do
  @moduledoc """
  Extracts named fields from raw CSV row strings for use in the reporting import pipeline.

  This extractor is used to pull specific columns from large CSV exports produced
  by third-party billing, ERP, and logistics platforms. Rather than loading entire
  files into memory, the pipeline streams lines and delegates field extraction here.

  Expected usage:

    header_map = CsvRowExtractor.build_header_map(raw_header_line, separator: ",")
    fields     = CsvRowExtractor.extract_fields(raw_data_line, header_map)

  The `header_map` is built once per file and reused for every subsequent data row.
  """

  require Logger

  @doc """
  Builds a header-name-to-column-index map from a raw CSV header line.

  Returns a map of `%{"column_name" => integer_index}`.
  """
  def build_header_map(header_line, opts \\ []) do
    sep = Keyword.get(opts, :separator, ",")

    header_line
    |> String.split(sep)
    |> Enum.map(&String.trim/1)
    |> Enum.with_index()
    |> Map.new(fn {name, idx} -> {name, idx} end)
  end

  @doc """
  Extracts all columns defined in `header_map` from a raw CSV data row string.

  Returns a map of `%{"column_name" => value_string}`.
  Cells that do not exist at the expected index are returned as `nil`.
  """

  def extract_fields(raw_row, header_map, opts \\ []) when is_binary(raw_row) and is_map(header_map) do
    sep    = Keyword.get(opts, :separator, ",")
    cells  = String.split(raw_row, sep)

    Map.new(header_map, fn {col_name, idx} ->
      value =
        cells
        |> Enum.at(idx)
        |> maybe_trim()

      {col_name, value}
    end)
  end

  @doc """
  Extracts only the specified subset of columns from a raw CSV row.

  Useful when only a few fields from a wide CSV are required.
  """
  def extract_subset(raw_row, header_map, desired_columns, opts \\ []) do
    sub_map = Map.take(header_map, desired_columns)
    extract_fields(raw_row, sub_map, opts)
  end

  @doc """
  Validates that all required columns were present and non-empty in the extracted map.

  Returns `:ok` or `{:error, {:missing_columns, [column_name]}}`.
  """
  def validate_required(extracted_map, required_columns) when is_list(required_columns) do
    missing =
      required_columns
      |> Enum.reject(fn col ->
        case Map.fetch(extracted_map, col) do
          {:ok, val} when is_binary(val) and val != "" -> true
          _                                            -> false
        end
      end)

    case missing do
      []   -> :ok
      cols -> {:error, {:missing_columns, cols}}
    end
  end

  @doc """
  Converts an extracted field map into a keyword list, useful for Ecto changesets.
  """
  def to_keyword_list(extracted_map) do
    Enum.map(extracted_map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> {:error, :unknown_column_atom}
  end

  @doc """
  Returns the number of columns detected in a header line.
  """
  def column_count(header_line, opts \\ []) do
    sep = Keyword.get(opts, :separator, ",")
    header_line |> String.split(sep) |> length()
  end

  @doc """
  Returns true when the extracted row has the expected number of columns.
  Used as a quick sanity check before field extraction.
  """
  def row_width_matches?(raw_row, header_map, opts \\ []) do
    sep   = Keyword.get(opts, :separator, ",")
    count = raw_row |> String.split(sep) |> length()
    count == map_size(header_map)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_trim(nil), do: nil

  defp maybe_trim(str) when is_binary(str) do
    trimmed = String.trim(str)
    if trimmed == "", do: nil, else: trimmed
  end
end
```
