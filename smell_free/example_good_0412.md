```elixir
defmodule Reports.PDFExporter do
  @moduledoc """
  Generates PDF export packages for domain reports. Each report module
  implements the `Reports.Exportable` behaviour to provide its own
  data-gathering and rendering logic. The exporter wraps the result in a
  named binary suitable for HTTP download or object storage upload.
  """

  @type export_name :: String.t()
  @type pdf_bytes :: binary()
  @type export_result :: {:ok, %{name: export_name(), bytes: pdf_bytes()}}
                       | {:error, :rendering_failed | :data_unavailable}

  @doc """
  Exports `module`'s report for the given `params`. Delegates data
  gathering and HTML rendering to the module, then converts to PDF.
  """
  @spec export(module(), map()) :: export_result()
  def export(module, params) when is_atom(module) and is_map(params) do
    with {:ok, data} <- module.gather_data(params),
         {:ok, html} <- module.render_html(data),
         {:ok, pdf} <- html_to_pdf(html) do
      name = module.filename(params)
      {:ok, %{name: name, bytes: pdf}}
    else
      {:error, :not_found} -> {:error, :data_unavailable}
      {:error, _} -> {:error, :rendering_failed}
    end
  end

  defp html_to_pdf(html) when is_binary(html) do
    case System.cmd("wkhtmltopdf", ["--quiet", "-", "-"], input: html, stderr_to_stdout: false) do
      {pdf_bytes, 0} -> {:ok, pdf_bytes}
      {_output, _code} -> {:error, :rendering_failed}
    end
  rescue
    ErlangError -> {:error, :rendering_failed}
  end
end

defmodule Reports.Exportable do
  @moduledoc "Behaviour for report modules that support PDF export."

  @doc "Gathers data required to render the report from the given params."
  @callback gather_data(params :: map()) :: {:ok, term()} | {:error, :not_found | term()}

  @doc "Renders the report data as an HTML string."
  @callback render_html(data :: term()) :: {:ok, String.t()} | {:error, term()}

  @doc "Returns the output filename for the PDF, given the original params."
  @callback filename(params :: map()) :: String.t()
end

defmodule Reports.SalesReport do
  @moduledoc "Monthly sales report with PDF export support."

  @behaviour Reports.Exportable

  alias Store.Catalog

  @impl Reports.Exportable
  def gather_data(%{month: month, year: year}) do
    orders = Catalog.orders_for_month(year, month)
    if is_list(orders), do: {:ok, orders}, else: {:error, :not_found}
  end

  def gather_data(_params), do: {:error, :not_found}

  @impl Reports.Exportable
  def render_html(orders) when is_list(orders) do
    rows = Enum.map_join(orders, "
", fn o ->
      "<tr><td>#{o.id}</td><td>#{o.total_cents}</td><td>#{o.status}</td></tr>"
    end)
    html = "<html><body><table><thead><tr><th>ID</th><th>Total</th><th>Status</th></tr></thead><tbody>#{rows}</tbody></table></body></html>"
    {:ok, html}
  end

  @impl Reports.Exportable
  def filename(%{month: month, year: year}) do
    "sales_report_#{year}_#{String.pad_leading(to_string(month), 2, "0")}.pdf"
  end

  def filename(_), do: "sales_report.pdf"
end
```
