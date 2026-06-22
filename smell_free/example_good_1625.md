```elixir
defmodule DataImport.CsvImporter do
  @moduledoc """
  Imports structured records from CSV binaries with per-column type casting and validation.

  Each row is independently validated and cast. Rows with validation errors are
  collected into the result rather than aborting the entire import.
  """

  alias DataImport.CsvImporter.{Schema, RowResult, ImportResult}

  @doc """
  Parses and validates a CSV binary against the given schema.

  Returns an `ImportResult` containing successful records and per-row errors.
  """
  @spec import(binary(), Schema.t()) :: {:ok, ImportResult.t()} | {:error, String.t()}
  def import(csv_binary, %Schema{} = schema) when is_binary(csv_binary) do
    with {:ok, rows} <- split_rows(csv_binary),
         {:ok, headers, data_rows} <- extract_headers(rows),
         :ok <- validate_headers(headers, schema) do
      results = Enum.with_index(data_rows, 2) |> Enum.map(&process_row(&1, headers, schema))
      {:ok, ImportResult.from_row_results(results)}
    end
  end

  def import(_, _), do: {:error, "invalid input"}

  defp split_rows(binary) do
    rows = binary |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    if rows == [], do: {:error, "empty CSV"}, else: {:ok, rows}
  end

  defp extract_headers([header_row | data_rows]) do
    headers = header_row |> String.split(",") |> Enum.map(&String.trim/1)
    {:ok, headers, data_rows}
  end

  defp extract_headers([]), do: {:error, "no rows in CSV"}

  defp validate_headers(headers, %Schema{required_columns: required}) do
    missing = required -- headers
    if missing == [], do: :ok, else: {:error, "missing columns: #{Enum.join(missing, ", ")}"}
  end

  defp process_row({row_string, line_number}, headers, schema) do
    values = row_string |> String.split(",") |> Enum.map(&String.trim/1)
    raw = Enum.zip(headers, values) |> Map.new()
    cast_and_validate(raw, line_number, schema)
  end

  defp cast_and_validate(raw, line_number, %Schema{columns: columns}) do
    {casted, errors} =
      Enum.reduce(columns, {%{}, []}, fn col, {acc, errs} ->
        raw_value = Map.get(raw, col.name)
        case Schema.Column.cast(col, raw_value) do
          {:ok, value} -> {Map.put(acc, col.name, value), errs}
          {:error, msg} -> {acc, [{col.name, msg} | errs]}
        end
      end)

    if errors == [] do
      RowResult.ok(line_number, casted)
    else
      RowResult.error(line_number, raw, errors)
    end
  end
end

defmodule DataImport.CsvImporter.Schema do
  @moduledoc "Describes expected columns and their types for CSV import."

  @enforce_keys [:columns]
  defstruct [:columns, required_columns: []]

  @type t :: %__MODULE__{
          columns: [Column.t()],
          required_columns: [String.t()]
        }

  defmodule Column do
    @moduledoc false

    @enforce_keys [:name, :type]
    defstruct [:name, :type, required: false]

    @type t :: %__MODULE__{name: String.t(), type: :string | :integer | :date, required: boolean()}

    @spec cast(t(), String.t() | nil) :: {:ok, term()} | {:error, String.t()}
    def cast(%__MODULE__{required: true}, nil), do: {:error, "is required"}
    def cast(%__MODULE__{required: true}, ""), do: {:error, "is required"}
    def cast(%__MODULE__{}, nil), do: {:ok, nil}
    def cast(%__MODULE__{}, ""), do: {:ok, nil}
    def cast(%__MODULE__{type: :string}, v) when is_binary(v), do: {:ok, v}
    def cast(%__MODULE__{type: :integer, name: name}, v) do
      case Integer.parse(v) do
        {int, ""} -> {:ok, int}
        _ -> {:error, "#{name} must be an integer"}
      end
    end
    def cast(%__MODULE__{type: :date, name: name}, v) do
      case Date.from_iso8601(v) do
        {:ok, date} -> {:ok, date}
        _ -> {:error, "#{name} must be a date in YYYY-MM-DD format"}
      end
    end
  end
end

defmodule DataImport.CsvImporter.RowResult do
  @moduledoc false

  defstruct [:line, :status, :record, :raw, :errors]

  @type t :: %__MODULE__{}

  def ok(line, record), do: %__MODULE__{line: line, status: :ok, record: record}
  def error(line, raw, errors), do: %__MODULE__{line: line, status: :error, raw: raw, errors: errors}
end

defmodule DataImport.CsvImporter.ImportResult do
  @moduledoc false

  defstruct [:records, :errors, :total_rows]

  @type t :: %__MODULE__{}

  def from_row_results(results) do
    {oks, errs} = Enum.split_with(results, &(&1.status == :ok))
    %__MODULE__{records: Enum.map(oks, & &1.record), errors: errs, total_rows: length(results)}
  end
end
```
