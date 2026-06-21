# File: `example_good_210.md`

```elixir
defmodule Import.CsvParser do
  @moduledoc """
  Parses CSV files into typed record maps according to a column schema.

  The schema declares expected column headers, their target field names,
  and optional type coercions. Rows with missing required columns or
  coercion failures are collected as errors rather than crashing the parse,
  so callers receive a complete picture of data quality in one pass.
  """

  @type field_name :: atom()
  @type coerce_fn :: (String.t() -> {:ok, term()} | {:error, String.t()})

  @type column_spec :: %{
          required(:header) => String.t(),
          required(:field) => field_name(),
          optional(:required) => boolean(),
          optional(:coerce) => coerce_fn()
        }

  @type row_result ::
          {:ok, map()}
          | {:error, %{row: pos_integer(), errors: [String.t()]}}

  @type parse_result :: %{
          records: [map()],
          errors: [%{row: pos_integer(), errors: [String.t()]}],
          total_rows: non_neg_integer()
        }

  @doc """
  Parses `csv_string` into typed records using the provided column schema.

  The first row is treated as the header row. Column matching is
  case-insensitive and trims surrounding whitespace.

  Returns a `parse_result` with all successfully parsed records and a
  separate list of row-level errors for failed rows.
  """
  @spec parse(String.t(), [column_spec()]) :: parse_result()
  def parse(csv_string, schema) when is_binary(csv_string) and is_list(schema) do
    rows = split_rows(csv_string)

    case rows do
      [] -> empty_result()
      [_header_only] -> empty_result()
      [header_row | data_rows] ->
        headers = parse_headers(header_row)
        results = data_rows |> Enum.with_index(2) |> Enum.map(&parse_row(&1, headers, schema))
        collate_results(results)
    end
  end

  @doc """
  Coercion helper: converts a string to an integer.
  """
  @spec coerce_integer(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def coerce_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "expected an integer, got #{inspect(value)}"}
    end
  end

  @doc """
  Coercion helper: converts a string to a float.
  """
  @spec coerce_float(String.t()) :: {:ok, float()} | {:error, String.t()}
  def coerce_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "expected a float, got #{inspect(value)}"}
    end
  end

  @doc """
  Coercion helper: parses an ISO 8601 date string.
  """
  @spec coerce_date(String.t()) :: {:ok, Date.t()} | {:error, String.t()}
  def coerce_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, _date} = ok -> ok
      {:error, _} -> {:error, "expected a date in YYYY-MM-DD format, got #{inspect(value)}"}
    end
  end

  defp split_rows(csv_string) do
    csv_string
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp parse_headers(header_row) do
    header_row
    |> String.split(",")
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp parse_row({row_string, row_number}, headers, schema) do
    cells = row_string |> String.split(",") |> Enum.map(&String.trim/1)
    cell_map = headers |> Enum.zip(cells) |> Map.new()

    errors_and_values =
      Enum.map(schema, &extract_field(cell_map, &1))

    errors = for {:error, msg} <- errors_and_values, do: msg

    if errors == [] do
      record = for {:ok, {field, value}} <- errors_and_values, into: %{}, do: {field, value}
      {:ok, record}
    else
      {:error, %{row: row_number, errors: errors}}
    end
  end

  defp extract_field(cell_map, spec) do
    header_key = String.downcase(spec.header)
    required = Map.get(spec, :required, true)
    raw_value = Map.get(cell_map, header_key, "")

    cond do
      raw_value == "" and required ->
        {:error, "column '#{spec.header}' is required but missing or empty"}

      raw_value == "" ->
        {:ok, {spec.field, nil}}

      Map.has_key?(spec, :coerce) ->
        apply_coercion(spec.field, raw_value, spec.coerce)

      true ->
        {:ok, {spec.field, raw_value}}
    end
  end

  defp apply_coercion(field, raw_value, coerce_fn) do
    case coerce_fn.(raw_value) do
      {:ok, coerced} -> {:ok, {field, coerced}}
      {:error, message} -> {:error, "column '#{field}': #{message}"}
    end
  end

  defp collate_results(results) do
    {records, errors} =
      Enum.reduce(results, {[], []}, fn
        {:ok, record}, {recs, errs} -> {[record | recs], errs}
        {:error, err}, {recs, errs} -> {recs, [err | errs]}
      end)

    %{
      records: Enum.reverse(records),
      errors: Enum.reverse(errors),
      total_rows: length(results)
    }
  end

  defp empty_result, do: %{records: [], errors: [], total_rows: 0}
end
```
