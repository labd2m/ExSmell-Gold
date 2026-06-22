```elixir
defmodule Reports.Generator do
  @moduledoc """
  Generates business reports in multiple output formats from structured data sources.

  Each format renderer is isolated; adding a new format requires implementing
  the `Reports.Renderer` behaviour and registering it in the format map.
  """

  alias Reports.{DataSource, Renderer, ReportManifest}
  alias Reports.Renderers.{CsvRenderer, JsonRenderer, HtmlRenderer}

  @supported_formats %{
    csv: CsvRenderer,
    json: JsonRenderer,
    html: HtmlRenderer
  }

  @type format :: :csv | :json | :html
  @type report_opts :: [date_range: Date.Range.t(), filters: map()]

  @doc """
  Generates a report binary for the given report type and output format.

  Returns `{:ok, {binary, content_type}}` or an error tuple.
  """
  @spec generate(String.t(), format(), report_opts()) ::
          {:ok, {binary(), String.t()}} | {:error, String.t()}
  def generate(report_type, format, opts \\ [])
      when is_binary(report_type) and is_atom(format) do
    with {:ok, renderer} <- fetch_renderer(format),
         {:ok, manifest} <- ReportManifest.fetch(report_type),
         {:ok, data} <- DataSource.load(manifest, opts),
         {:ok, output} <- Renderer.render(renderer, manifest, data) do
      {:ok, {output, renderer.content_type()}}
    end
  end

  @doc """
  Returns the list of supported export formats.
  """
  @spec supported_formats() :: [format()]
  def supported_formats, do: Map.keys(@supported_formats)

  @doc """
  Returns true if the given format atom is supported.
  """
  @spec supports_format?(format()) :: boolean()
  def supports_format?(format), do: Map.has_key?(@supported_formats, format)

  defp fetch_renderer(format) do
    case Map.fetch(@supported_formats, format) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "unsupported format: #{format}"}
    end
  end
end

defmodule Reports.Renderer do
  @moduledoc "Behaviour contract for report format renderers."

  @callback render(ReportManifest.t(), [map()]) :: {:ok, binary()} | {:error, String.t()}
  @callback content_type() :: String.t()

  @spec render(module(), Reports.ReportManifest.t(), [map()]) ::
          {:ok, binary()} | {:error, String.t()}
  def render(renderer_module, manifest, data) do
    renderer_module.render(manifest, data)
  end
end

defmodule Reports.ReportManifest do
  @moduledoc "Metadata describing a report: its columns, title, and data query."

  @enforce_keys [:type, :title, :columns]
  defstruct [:type, :title, :columns, :query_module]

  @type column :: %{key: atom(), label: String.t(), type: :string | :number | :date}

  @type t :: %__MODULE__{
          type: String.t(),
          title: String.t(),
          columns: [column()],
          query_module: module() | nil
        }

  @known_manifests %{
    "sales_summary" => %__MODULE__{
      type: "sales_summary",
      title: "Sales Summary Report",
      columns: [
        %{key: :date, label: "Date", type: :date},
        %{key: :orders, label: "Orders", type: :number},
        %{key: :revenue_cents, label: "Revenue (cents)", type: :number}
      ],
      query_module: Reports.Queries.SalesSummary
    }
  }

  @spec fetch(String.t()) :: {:ok, t()} | {:error, String.t()}
  def fetch(report_type) when is_binary(report_type) do
    case Map.fetch(@known_manifests, report_type) do
      {:ok, manifest} -> {:ok, manifest}
      :error -> {:error, "unknown report type: #{report_type}"}
    end
  end
end

defmodule Reports.Renderers.CsvRenderer do
  @moduledoc "Renders report data as a CSV binary."

  @behaviour Reports.Renderer

  alias Reports.ReportManifest

  @impl Reports.Renderer
  def content_type, do: "text/csv"

  @impl Reports.Renderer
  def render(%ReportManifest{columns: columns}, data) when is_list(data) do
    header = columns |> Enum.map(& &1.label) |> Enum.join(",")

    rows =
      Enum.map(data, fn row ->
        columns |> Enum.map(&to_string(Map.get(row, &1.key, ""))) |> Enum.join(",")
      end)

    {:ok, ([header | rows] |> Enum.join("\n")) <> "\n"}
  end

  def render(_, _), do: {:error, "cannot render CSV from invalid data"}
end
```
