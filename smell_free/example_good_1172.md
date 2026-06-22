**File:** `example_good_1172.md`

```elixir
defmodule Reports.ReportData do
  @moduledoc "Represents a fully resolved report dataset ready for export."

  @enforce_keys [:title, :columns, :rows, :generated_at]
  defstruct [:title, :columns, :rows, :generated_at, :filters]

  @type column :: %{key: atom(), label: String.t(), type: :string | :integer | :float | :date}
  @type row :: %{atom() => term()}
  @type t :: %__MODULE__{
          title: String.t(),
          columns: [column()],
          rows: [row()],
          generated_at: DateTime.t(),
          filters: map() | nil
        }
end

defmodule Reports.Exporter do
  @moduledoc "Behaviour for report export format implementations."

  alias Reports.ReportData

  @doc "Serializes report data to a binary in the target format."
  @callback export(ReportData.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Returns the file extension for this export format."
  @callback file_extension() :: String.t()

  @doc "Returns the MIME type for this export format."
  @callback mime_type() :: String.t()
end

defmodule Reports.Exporters.CSV do
  @moduledoc "Exports report data as UTF-8 CSV with a header row."

  @behaviour Reports.Exporter

  alias Reports.ReportData

  @impl Reports.Exporter
  def file_extension, do: "csv"

  @impl Reports.Exporter
  def mime_type, do: "text/csv"

  @impl Reports.Exporter
  def export(%ReportData{columns: columns, rows: rows}) do
    header = columns |> Enum.map(& &1.label) |> encode_row()

    data_rows =
      Enum.map(rows, fn row ->
        columns
        |> Enum.map(fn col -> format_cell(Map.get(row, col.key), col.type) end)
        |> encode_row()
      end)

    csv = ([header | data_rows] |> Enum.join("\n")) <> "\n"
    {:ok, csv}
  end

  defp encode_row(cells) do
    cells |> Enum.map(&escape_cell/1) |> Enum.join(",")
  end

  defp escape_cell(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp escape_cell(value), do: to_string(value)

  defp format_cell(nil, _type), do: ""
  defp format_cell(%Date{} = d, :date), do: Date.to_iso8601(d)
  defp format_cell(value, :float) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_cell(value, _type), do: to_string(value)
end

defmodule Reports.Exporters.JSON do
  @moduledoc "Exports report data as a structured JSON document."

  @behaviour Reports.Exporter

  alias Reports.ReportData

  @impl Reports.Exporter
  def file_extension, do: "json"

  @impl Reports.Exporter
  def mime_type, do: "application/json"

  @impl Reports.Exporter
  def export(%ReportData{} = report) do
    payload = %{
      title: report.title,
      generated_at: DateTime.to_iso8601(report.generated_at),
      columns: Enum.map(report.columns, &Map.take(&1, [:key, :label, :type])),
      rows: Enum.map(report.rows, &stringify_keys/1),
      total_rows: length(report.rows)
    }

    case Jason.encode(payload) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encoding_failed, reason}}
    end
  end

  defp stringify_keys(row) do
    Map.new(row, fn {k, v} -> {to_string(k), v} end)
  end
end

defmodule Reports do
  @moduledoc """
  Public interface for exporting report data in a requested format.
  """

  alias Reports.{Exporters, ReportData}

  @exporters %{
    "csv" => Exporters.CSV,
    "json" => Exporters.JSON
  }

  @type export_result :: {:ok, %{data: binary(), mime_type: String.t(), filename: String.t()}}
                       | {:error, term()}

  @spec export(ReportData.t(), String.t()) :: export_result()
  def export(%ReportData{} = report, format) when is_binary(format) do
    case Map.fetch(@exporters, String.downcase(format)) do
      {:ok, exporter} ->
        with {:ok, data} <- exporter.export(report) do
          filename = build_filename(report.title, exporter.file_extension())
          {:ok, %{data: data, mime_type: exporter.mime_type(), filename: filename}}
        end

      :error ->
        {:error, {:unsupported_format, format}}
    end
  end

  defp build_filename(title, ext) do
    slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    "#{slug}.#{ext}"
  end
end
```
