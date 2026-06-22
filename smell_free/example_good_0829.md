```elixir
defmodule Exporter.Format do
  @moduledoc false

  @type t :: :json | :ndjson | :csv

  @spec mime_type(t()) :: String.t()
  def mime_type(:json), do: "application/json"
  def mime_type(:ndjson), do: "application/x-ndjson"
  def mime_type(:csv), do: "text/csv"

  @spec extension(t()) :: String.t()
  def extension(:json), do: "json"
  def extension(:ndjson), do: "ndjson"
  def extension(:csv), do: "csv"

  @spec from_string(String.t()) :: {:ok, t()} | {:error, :unsupported_format}
  def from_string("json"), do: {:ok, :json}
  def from_string("ndjson"), do: {:ok, :ndjson}
  def from_string("csv"), do: {:ok, :csv}
  def from_string(_), do: {:error, :unsupported_format}
end

defmodule Exporter.ColumnSpec do
  @moduledoc false

  @type t :: %__MODULE__{field: atom(), header: String.t(), formatter: (term() -> String.t()) | nil}

  defstruct [:field, :header, :formatter]

  @spec new(atom(), String.t(), (term() -> String.t()) | nil) :: t()
  def new(field, header, formatter \\ nil) do
    %__MODULE__{field: field, header: header, formatter: formatter}
  end
end

defmodule Exporter do
  @moduledoc """
  Exports a list of record maps to a binary payload in one of several
  supported formats: JSON array, newline-delimited JSON, or RFC 4180 CSV.

  Column specs declare which fields to include, the header label, and
  an optional per-field formatter function. This keeps projection and
  formatting concerns out of the domain model.
  """

  alias Exporter.{ColumnSpec, Format}

  @type opts :: [columns: [ColumnSpec.t()]]

  @spec export([map()], Format.t(), opts()) :: {:ok, binary()} | {:error, term()}
  def export(records, format, opts \\ []) when is_list(records) do
    columns = Keyword.get(opts, :columns, infer_columns(records))

    case format do
      :json -> encode_json(records, columns)
      :ndjson -> encode_ndjson(records, columns)
      :csv -> encode_csv(records, columns)
    end
  end

  defp encode_json(records, columns) do
    projected = Enum.map(records, &project(&1, columns))

    case Jason.encode(projected) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp encode_ndjson(records, columns) do
    result =
      records
      |> Enum.map_join("\n", fn record ->
        record |> project(columns) |> Jason.encode!()
      end)

    {:ok, result}
  rescue
    error -> {:error, {:encode_failed, error}}
  end

  defp encode_csv(records, columns) do
    header_row = columns |> Enum.map_join(",", &csv_escape(&1.header))
    data_rows = Enum.map(records, fn record ->
      columns |> Enum.map_join(",", fn col ->
        value = Map.get(record, col.field) |> format_value(col.formatter)
        csv_escape(value)
      end)
    end)

    {:ok, Enum.join([header_row | data_rows], "\r\n")}
  end

  defp project(record, columns) do
    Map.new(columns, fn col ->
      value = Map.get(record, col.field) |> format_value(col.formatter)
      {col.header, value}
    end)
  end

  defp format_value(nil, _formatter), do: nil
  defp format_value(value, nil), do: value
  defp format_value(value, formatter) when is_function(formatter, 1), do: formatter.(value)

  defp csv_escape(nil), do: ""
  defp csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\r", "\n"]) do
      ~s("#{String.replace(value, "\"", "\"\"")}")
    else
      value
    end
  end
  defp csv_escape(value), do: to_string(value)

  defp infer_columns([first | _]) when is_map(first) do
    first |> Map.keys() |> Enum.map(fn key ->
      label = if is_atom(key), do: Atom.to_string(key), else: key
      %ColumnSpec{field: key, header: label}
    end)
  end
  defp infer_columns(_), do: []
end
```
