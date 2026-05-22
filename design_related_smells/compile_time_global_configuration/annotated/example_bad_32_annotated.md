# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@default_format` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `generate/2`, `export/3`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to set `@default_format`. Because the application environment is unavailable during compilation, Elixir can raise an `ArgumentError` or emit a warning. The atom value is embedded in the bytecode, so changing the default output format in a running system requires recompilation.

---

```elixir
defmodule Reporting.ReportBuilder do
  @moduledoc """
  Builds financial and operational reports and exports them in a
  configurable format. Supported output formats are :csv, :json, and :pdf.
  The default format is driven by application configuration.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called
  # VALIDATION: while the module is being compiled. At compile-time, the
  # VALIDATION: :reporting application has not yet been loaded into the
  # VALIDATION: application environment, so Elixir raises:
  # VALIDATION:   ** (ArgumentError) could not fetch application environment
  # VALIDATION:     :default_report_format for application :reporting
  # VALIDATION: The resolved atom is also baked into the beam bytecode,
  # VALIDATION: making runtime format changes impossible without recompiling.
  @default_format Application.fetch_env!(:reporting, :default_report_format)
  # VALIDATION: SMELL END

  @supported_formats [:csv, :json, :pdf]
  @max_rows_per_page 500

  @type report_row :: map()
  @type report_format :: :csv | :json | :pdf
  @type report_options :: %{
          optional(:format) => report_format(),
          optional(:title) => String.t(),
          optional(:date_range) => {Date.t(), Date.t()},
          optional(:include_totals) => boolean()
        }

  @spec generate(String.t(), report_options()) ::
          {:ok, %{data: binary(), format: report_format(), row_count: non_neg_integer()}}
          | {:error, :invalid_format | :data_fetch_error | :render_error}
  def generate(report_type, opts \\ %{}) do
    format = Map.get(opts, :format, @default_format)

    unless format in @supported_formats do
      {:error, :invalid_format}
    else
      with {:ok, rows} <- fetch_data(report_type, opts),
           {:ok, rendered} <- render(rows, format, opts) do
        Logger.info("Report generated",
          type: report_type,
          format: format,
          row_count: length(rows)
        )

        {:ok, %{data: rendered, format: format, row_count: length(rows)}}
      else
        {:error, :data_fetch_error} = err ->
          Logger.error("Report data fetch failed", type: report_type)
          err

        {:error, :render_error} = err ->
          Logger.error("Report render failed", type: report_type, format: format)
          err
      end
    end
  end

  @spec export(String.t(), String.t(), report_options()) ::
          {:ok, String.t()} | {:error, atom()}
  def export(report_type, destination_path, opts \\ %{}) do
    with {:ok, %{data: data, format: format}} <- generate(report_type, opts),
         :ok <- write_file(destination_path, data) do
      Logger.info("Report exported",
        type: report_type,
        format: format,
        path: destination_path
      )

      {:ok, destination_path}
    end
  end

  @spec list_supported_formats() :: [report_format()]
  def list_supported_formats, do: @supported_formats

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_data(report_type, opts) do
    date_range = Map.get(opts, :date_range, default_date_range())

    case data_source().query(report_type, date_range) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, _} -> {:error, :data_fetch_error}
    end
  end

  defp render(rows, :csv, opts) do
    include_totals = Map.get(opts, :include_totals, false)
    title = Map.get(opts, :title, "Report")

    rows_with_totals = if include_totals, do: rows ++ [totals_row(rows)], else: rows

    csv =
      rows_with_totals
      |> Enum.map(&row_to_csv/1)
      |> then(&[csv_header(title) | &1])
      |> Enum.join("\n")

    {:ok, csv}
  rescue
    _ -> {:error, :render_error}
  end

  defp render(rows, :json, opts) do
    title = Map.get(opts, :title, "Report")

    payload = %{
      title: title,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      rows: rows
    }

    case Jason.encode(payload) do
      {:ok, json} -> {:ok, json}
      _ -> {:error, :render_error}
    end
  end

  defp render(_rows, :pdf, _opts) do
    {:error, :render_error}
  end

  defp row_to_csv(row) do
    row
    |> Map.values()
    |> Enum.map(&to_string/1)
    |> Enum.map(&escape_csv_field/1)
    |> Enum.join(",")
  end

  defp escape_csv_field(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"#{String.replace(field, "\"", "\"\"")}\""
    else
      field
    end
  end

  defp csv_header(title), do: "# #{title}"

  defp totals_row(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      Map.merge(acc, row, fn _k, v1, v2 ->
        if is_number(v1) and is_number(v2), do: v1 + v2, else: v1
      end)
    end)
    |> Map.put(:__type__, :total)
  end

  defp write_file(path, data) do
    case File.write(path, data) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("Failed to write report", path: path, reason: reason)
        {:error, :write_failed}
    end
  end

  defp default_date_range do
    today = Date.utc_today()
    {Date.add(today, -30), today}
  end

  defp data_source, do: Application.get_env(:reporting, :data_source, Reporting.DataSource)
end
```
