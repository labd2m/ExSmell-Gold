```elixir
defmodule CsvExport.Column do
  @moduledoc """
  Defines a single column in a CSV export: its header label and
  a function that extracts and formats the value from a row struct.
  """

  @type t :: %__MODULE__{
          header: String.t(),
          extractor: (term() -> String.t())
        }

  defstruct [:header, :extractor]
end

defmodule CsvExport.Schema do
  alias CsvExport.Column

  @moduledoc """
  A collection of `Column` definitions describing a complete CSV schema.
  """

  @type t :: %__MODULE__{columns: [Column.t()]}
  defstruct columns: []

  @spec new([Column.t()]) :: t()
  def new(columns) when is_list(columns), do: %__MODULE__{columns: columns}

  @spec headers(t()) :: [String.t()]
  def headers(%__MODULE__{columns: columns}), do: Enum.map(columns, & &1.header)

  @spec extract_row(t(), term()) :: [String.t()]
  def extract_row(%__MODULE__{columns: columns}, record) do
    Enum.map(columns, fn col -> safe_extract(col.extractor, record) end)
  end

  defp safe_extract(extractor, record) do
    case extractor.(record) do
      nil -> ""
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end
end

defmodule CsvExport.Writer do
  alias CsvExport.Schema

  @moduledoc """
  Streams a lazily-evaluated enumerable of records through a CSV schema
  and writes UTF-8 encoded output to any `IO` device or accumulates
  into a binary for in-memory use.
  """

  @bom <<0xEF, 0xBB, 0xBF>>

  @spec stream_to_device(Enumerable.t(), Schema.t(), IO.device(), keyword()) :: :ok
  def stream_to_device(records, %Schema{} = schema, device, opts \\ []) do
    include_bom = Keyword.get(opts, :bom, false)

    if include_bom, do: IO.write(device, @bom)

    IO.write(device, encode_row(Schema.headers(schema)))

    records
    |> Stream.each(fn record ->
      row = Schema.extract_row(schema, record)
      IO.write(device, encode_row(row))
    end)
    |> Stream.run()
  end

  @spec to_binary(Enumerable.t(), Schema.t(), keyword()) :: {:ok, binary()}
  def to_binary(records, %Schema{} = schema, opts \\ []) do
    include_bom = Keyword.get(opts, :bom, false)
    prefix = if include_bom, do: @bom, else: ""

    rows =
      records
      |> Enum.map(fn record ->
        schema
        |> Schema.extract_row(record)
        |> encode_row()
      end)

    output = IO.iodata_to_binary([prefix, encode_row(Schema.headers(schema)) | rows])
    {:ok, output}
  end

  defp encode_row(fields) do
    fields
    |> Enum.map(&escape_field/1)
    |> Enum.join(",")
    |> then(&(&1 <> "\r\n"))
  end

  defp escape_field(value) when is_binary(value) do
    needs_quoting =
      String.contains?(value, [",", "\"", "\n", "\r"])

    if needs_quoting do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end
end
```
