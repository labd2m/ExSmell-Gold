# Annotated Example 05 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Reporting.Generator.build_sales_report/11`
- **Affected function(s):** `build_sales_report/11`
- **Short explanation:** The function requires 11 separate positional parameters covering date ranges, filters, grouping, formatting, and export options. These naturally belong in a report-options struct or keyword list.

---

```elixir
defmodule Reporting.Generator do
  @moduledoc """
  Generates configurable sales reports with filtering, grouping, and export support.
  """

  require Logger

  alias Reporting.{DataFetcher, Formatter, Exporter, ReportResult}

  @groupings [:day, :week, :month, :quarter, :year]
  @formats [:pdf, :csv, :xlsx, :json]
  @sort_orders [:asc, :desc]

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 11 parameters are listed positionally,
  # VALIDATION: covering entirely different concerns: date range, filters, grouping,
  # VALIDATION: display format, and output preferences. A single options struct would
  # VALIDATION: make this interface far less error-prone.
  def build_sales_report(
        start_date,
        end_date,
        region_filter,
        product_category_filter,
        sales_rep_id,
        group_by,
        include_refunds,
        include_taxes,
        sort_order,
        output_format,
        send_to_email
      ) do
    # VALIDATION: SMELL END

    with :ok <- validate_date_range(start_date, end_date),
         :ok <- validate_grouping(group_by),
         :ok <- validate_format(output_format),
         :ok <- validate_sort_order(sort_order) do

      Logger.info("Building sales report from #{start_date} to #{end_date}")

      filters = %{
        region: region_filter,
        product_category: product_category_filter,
        sales_rep_id: sales_rep_id,
        include_refunds: include_refunds,
        include_taxes: include_taxes
      }

      {:ok, raw_data} = DataFetcher.fetch_sales(start_date, end_date, filters)

      grouped_data = DataFetcher.group_by(raw_data, group_by)

      sorted_data =
        case sort_order do
          :asc -> Enum.sort_by(grouped_data, & &1.period)
          :desc -> Enum.sort_by(grouped_data, & &1.period, :desc)
        end

      summary = compute_summary(sorted_data, include_taxes, include_refunds)

      report = %ReportResult{
        generated_at: DateTime.utc_now(),
        period: %{start: start_date, end: end_date},
        filters: filters,
        group_by: group_by,
        rows: sorted_data,
        summary: summary
      }

      formatted = Formatter.format(report, output_format)

      output_path =
        Exporter.export(
          formatted,
          output_format,
          "sales_report_#{Date.to_iso8601(start_date)}_#{Date.to_iso8601(end_date)}"
        )

      if send_to_email do
        Reporting.Mailer.send_report(send_to_email, output_path, output_format)
        Logger.info("Report dispatched to #{send_to_email}")
      end

      {:ok, %{report: report, path: output_path}}
    end
  end

  defp validate_date_range(start_date, end_date) do
    if Date.compare(start_date, end_date) != :gt, do: :ok, else: {:error, :invalid_date_range}
  end

  defp validate_grouping(g) when g in @groupings, do: :ok
  defp validate_grouping(g), do: {:error, {:invalid_grouping, g}}

  defp validate_format(f) when f in @formats, do: :ok
  defp validate_format(f), do: {:error, {:unsupported_format, f}}

  defp validate_sort_order(o) when o in @sort_orders, do: :ok
  defp validate_sort_order(o), do: {:error, {:invalid_sort_order, o}}

  defp compute_summary(rows, include_taxes, include_refunds) do
    total_revenue = Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.revenue))

    tax_total =
      if include_taxes,
        do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.tax)),
        else: Decimal.new(0)

    refund_total =
      if include_refunds,
        do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.refunds)),
        else: Decimal.new(0)

    %{
      total_revenue: total_revenue,
      tax_total: tax_total,
      refund_total: refund_total,
      net_revenue: Decimal.sub(Decimal.sub(total_revenue, tax_total), refund_total)
    }
  end
end
```
