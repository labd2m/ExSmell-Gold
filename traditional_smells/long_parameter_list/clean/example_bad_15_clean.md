```elixir
defmodule Reporting.Generator do
  @moduledoc """
  Builds sales reports from aggregated transaction data, supporting multiple
  output formats and optional chart generation.
  """

  require Logger

  alias Reporting.DataStore
  alias Reporting.Formatters.CSVFormatter
  alias Reporting.Formatters.PDFFormatter
  alias Reporting.Formatters.JSONFormatter
  alias Reporting.ChartBuilder
  alias Reporting.Mailer

  @valid_formats [:csv, :pdf, :json]
  @valid_groups [:day, :week, :month, :rep, :region]

  def generate_sales_report(
        date_from,
        date_to,
        region,
        product_category,
        sales_rep_id,
        format,
        group_by,
        recipient_email,
        include_chart
      ) do
    with :ok <- validate_date_range(date_from, date_to),
         :ok <- validate_format(format),
         :ok <- validate_group(group_by) do
      filters = %{
        date_from: date_from,
        date_to: date_to,
        region: region,
        product_category: product_category,
        sales_rep_id: sales_rep_id
      }

      Logger.info("Generating #{format} sales report [#{date_from} – #{date_to}]")

      raw_data = DataStore.fetch_sales(filters)
      grouped = DataStore.group_by(raw_data, group_by)
      summary = compute_summary(grouped)

      chart_data =
        if include_chart do
          ChartBuilder.build_sales_chart(grouped)
        else
          nil
        end

      rendered =
        case format do
          :csv -> CSVFormatter.render(grouped, summary)
          :pdf -> PDFFormatter.render(grouped, summary, chart_data)
          :json -> JSONFormatter.render(grouped, summary)
        end

      if recipient_email do
        Mailer.send_report(recipient_email, rendered, format)
        Logger.info("Report delivered to #{recipient_email}")
      end

      {:ok, %{data: rendered, summary: summary, format: format}}
    end
  end

  defp validate_date_range(date_from, date_to) do
    with {:ok, from} <- Date.from_iso8601(date_from),
         {:ok, to} <- Date.from_iso8601(date_to) do
      if Date.compare(from, to) != :gt, do: :ok, else: {:error, :invalid_date_range}
    else
      _ -> {:error, :invalid_date_format}
    end
  end

  defp validate_format(f) when f in @valid_formats, do: :ok
  defp validate_format(f), do: {:error, {:unsupported_format, f}}

  defp validate_group(g) when g in @valid_groups, do: :ok
  defp validate_group(g), do: {:error, {:unsupported_group, g}}

  defp compute_summary(grouped) do
    Enum.reduce(grouped, %{total_revenue: 0, total_units: 0, record_count: 0}, fn {_k, rows}, acc ->
      %{
        total_revenue: acc.total_revenue + Enum.sum(Enum.map(rows, & &1.revenue)),
        total_units: acc.total_units + Enum.sum(Enum.map(rows, & &1.units)),
        record_count: acc.record_count + length(rows)
      }
    end)
  end
end
```
