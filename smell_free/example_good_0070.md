```elixir
defmodule DataImport.ColumnSpec do
  @moduledoc false

  @type coerce_type :: :string | :integer | :float | :boolean | :date

  @type t :: %__MODULE__{
          name: String.t(),
          type: coerce_type(),
          required: boolean()
        }

  defstruct [:name, :type, required: true]

  @spec new(String.t(), coerce_type(), boolean()) :: t()
  def new(name, type, required \\ true)
      when is_binary(name) and type in [:string, :integer, :float, :boolean, :date] do
    %__MODULE__{name: name, type: type, required: required}
  end
end

defmodule DataImport.CsvParser do
  @moduledoc """
  Parses structured CSV input into typed row maps using a declared column spec.

  Each row is validated and coerced independently. Failures are collected
  and returned as a tagged list so callers can distinguish partial failures
  from complete success without raising exceptions.

  The parser trims whitespace from all field values and treats empty strings
  as absent values; required fields that are absent produce a typed error.
  """

  alias DataImport.ColumnSpec

  @type row_number :: pos_integer()
  @type row_error :: {row_number(), String.t(), atom()}
  @type parse_result :: {:ok, [map()]} | {:error, [row_error()]}

  @spec parse(String.t(), [ColumnSpec.t()]) :: parse_result()
  def parse(raw_csv, specs) when is_binary(raw_csv) and is_list(specs) do
    raw_csv
    |> split_lines()
    |> skip_header()
    |> Enum.with_index(2)
    |> Enum.map(fn {line, row_num} -> parse_row(line, row_num, specs) end)
    |> collect_results()
  end

  defp split_lines(csv), do: String.split(csv, ~r/\r?\n/, trim: true)

  defp skip_header([_header | rows]), do: rows
  defp skip_header([]), do: []

  defp parse_row(line, row_num, specs) do
    raw_fields = String.split(line, ",")

    if length(raw_fields) < length(specs) do
      {:error, {row_num, "_row", :too_few_columns}}
    else
      coerce_all_fields(raw_fields, specs, row_num)
    end
  end

  defp coerce_all_fields(fields, specs, row_num) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {spec, pos}, {:ok, acc} ->
      raw = fields |> Enum.at(pos, "") |> String.trim()

      case coerce(raw, spec) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, spec.name, value)}}
        {:error, reason} -> {:halt, {:error, {row_num, spec.name, reason}}}
      end
    end)
  end

  defp coerce("", %ColumnSpec{required: true}), do: {:error, :required_field_missing}
  defp coerce("", %ColumnSpec{required: false}), do: {:ok, nil}
  defp coerce(value, %ColumnSpec{type: :string}), do: {:ok, value}

  defp coerce(value, %ColumnSpec{type: :integer}) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_integer}
    end
  end

  defp coerce(value, %ColumnSpec{type: :float}) do
    case Float.parse(value) do
      {f, ""} -> {:ok, f}
      _ -> {:error, :invalid_float}
    end
  end

  defp coerce("true", %ColumnSpec{type: :boolean}), do: {:ok, true}
  defp coerce("false", %ColumnSpec{type: :boolean}), do: {:ok, false}
  defp coerce(_, %ColumnSpec{type: :boolean}), do: {:error, :invalid_boolean}

  defp coerce(value, %ColumnSpec{type: :date}) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_date}
    end
  end

  defp collect_results(results) do
    errors = for {:error, info} <- results, do: info

    if errors == [] do
      {:ok, for({:ok, row} <- results, do: row)}
    else
      {:error, errors}
    end
  end
end
```
