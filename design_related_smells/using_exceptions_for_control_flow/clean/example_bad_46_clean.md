```elixir
defmodule ReportExporter do
  @moduledoc """
  Serialises tabular report data into CSV format for download or archival.
  Supports configurable column ordering and header labels.
  """

  @default_separator ","
  @bom "\uFEFF"

  @allowed_columns ~w(
    period
    customer_id
    customer_name
    revenue
    refunds
    net_revenue
    transaction_count
    average_order_value
  )a

  def to_csv(rows, opts \\ []) do
    columns = Keyword.get(opts, :columns, @allowed_columns)
    separator = Keyword.get(opts, :separator, @default_separator)
    include_bom = Keyword.get(opts, :include_bom, true)

    if rows == [] or is_nil(rows) do
      raise RuntimeError, message: "Cannot export an empty dataset to CSV"
    end

    invalid_cols = Enum.reject(columns, &(&1 in @allowed_columns))

    unless invalid_cols == [] do
      raise RuntimeError,
        message:
          "Unknown column(s) specified: #{Enum.map_join(invalid_cols, ", ", &inspect/1)}. " <>
            "Allowed: #{Enum.join(@allowed_columns, ", ")}"
    end

    header_labels =
      Enum.map(columns, fn col ->
        col
        |> Atom.to_string()
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
      end)

    header_line = Enum.join(header_labels, separator)

    data_lines =
      Enum.map(rows, fn row ->
        columns
        |> Enum.map(fn col ->
          val = Map.get(row, col, "")
          escape_csv_value(val, separator)
        end)
        |> Enum.join(separator)
      end)

    all_lines = [header_line | data_lines]
    content = Enum.join(all_lines, "\r\n")

    if include_bom, do: @bom <> content, else: content
  end

  defp escape_csv_value(val, sep) when is_binary(val) do
    if String.contains?(val, [sep, "\"", "\n", "\r"]) do
      "\"" <> String.replace(val, "\"", "\"\"") <> "\""
    else
      val
    end
  end

  defp escape_csv_value(val, _sep) when is_number(val), do: to_string(val)
  defp escape_csv_value(nil, _sep), do: ""
  defp escape_csv_value(val, _sep), do: to_string(val)
end

defmodule ReportingPipeline do
  @moduledoc """
  Orchestrates monthly revenue report generation, export, and archival.
  """

  require Logger

  alias ReportExporter

  @export_columns ~w(period customer_id customer_name revenue refunds net_revenue)a

  def export_monthly_report(year, month, rows) do
    period_label = "#{year}-#{String.pad_leading(to_string(month), 2, "0")}"

    Logger.info("Starting CSV export for period #{period_label} (#{length(rows)} rows)")

    # Forced to use try/rescue because ReportExporter.to_csv/2 raises
    # RuntimeError for expected conditions like empty rows.
    try do
      csv_content =
        ReportExporter.to_csv(rows,
          columns: @export_columns,
          include_bom: true
        )

      filename = "revenue_report_#{period_label}.csv"
      byte_size = byte_size(csv_content)

      Logger.info("Export successful: #{filename} (#{byte_size} bytes)")

      {:ok,
       %{
         filename: filename,
         content: csv_content,
         byte_size: byte_size,
         period: period_label,
         row_count: length(rows),
         exported_at: DateTime.utc_now()
       }}
    rescue
      e in RuntimeError ->
        Logger.warning(
          "CSV export failed for period #{period_label}: #{e.message}"
        )

        {:error, e.message}
    end
  end

  def schedule_exports(year, months_and_rows) do
    Enum.map(months_and_rows, fn {month, rows} ->
      result = export_monthly_report(year, month, rows)

      case result do
        {:ok, meta} ->
          Logger.info("Archived #{meta.filename} (#{meta.row_count} rows)")
          {month, :ok}

        {:error, reason} ->
          Logger.error("Skipped month #{month}: #{reason}")
          {month, {:error, reason}}
      end
    end)
  end

  def build_summary_row(customer, period, transactions) do
    total_revenue = Enum.reduce(transactions, 0.0, &(&1.amount + &2))
    total_refunds = Enum.reduce(transactions, 0.0, &((&1[:refund] || 0.0) + &2))

    %{
      period: period,
      customer_id: customer.id,
      customer_name: customer.name,
      revenue: Float.round(total_revenue, 2),
      refunds: Float.round(total_refunds, 2),
      net_revenue: Float.round(total_revenue - total_refunds, 2),
      transaction_count: length(transactions),
      average_order_value:
        if(length(transactions) > 0,
          do: Float.round(total_revenue / length(transactions), 2),
          else: 0.0
        )
    }
  end
end
```
