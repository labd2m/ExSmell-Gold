# Annotated Example – Code Smell

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Reporting.Generator.build_sales_report/11` |
| **Affected function(s)** | `build_sales_report/11` |
| **Short explanation** | The function takes 11 parameters that govern a report's date range, grouping, filtering, and output format. A `%ReportConfig{}` struct would encapsulate this configuration, make defaults manageable, and allow callers to omit fields they do not care about instead of threading `nil` through every position. |

```elixir
defmodule Reporting.Generator do
  @moduledoc """
  Builds configurable sales reports for internal dashboards and exports.
  """

  require Logger

  @valid_groupings ~w(day week month quarter year)
  @valid_formats ~w(json csv pdf)
  @valid_statuses ~w(completed refunded cancelled all)

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 11 parameters are required to
  # configure a single report. Callers who forget to pass `include_taxes`
  # or swap `start_date` with `end_date` produce silently wrong reports.
  # A %ReportConfig{} struct with sensible defaults would be far safer and
  # more expressive.
  def build_sales_report(
        tenant_id,
        start_date,
        end_date,
        grouping,
        product_category,
        region_filter,
        order_status,
        include_taxes,
        include_refunds,
        currency,
        output_format
      ) do
    # VALIDATION: SMELL END
    with :ok <- validate_dates(start_date, end_date),
         :ok <- validate_grouping(grouping),
         :ok <- validate_status(order_status),
         :ok <- validate_format(output_format) do
      filters = %{
        tenant_id: tenant_id,
        start_date: start_date,
        end_date: end_date,
        product_category: product_category,
        region: region_filter,
        order_status: order_status,
        currency: currency
      }

      raw_data = fetch_sales_data(filters)

      aggregated =
        raw_data
        |> group_by_period(grouping)
        |> maybe_include_taxes(include_taxes)
        |> maybe_include_refunds(include_refunds)

      report = %{
        tenant_id: tenant_id,
        generated_at: DateTime.utc_now(),
        period: %{from: start_date, to: end_date},
        grouping: grouping,
        filters: filters,
        rows: aggregated,
        row_count: length(aggregated)
      }

      case render(report, output_format) do
        {:ok, content} ->
          Logger.info("Sales report generated for tenant #{tenant_id}: #{length(aggregated)} rows")
          {:ok, content}

        {:error, reason} ->
          Logger.error("Render failed: #{inspect(reason)}")
          {:error, :render_failed}
      end
    end
  end

  defp validate_dates(%Date{} = start_date, %Date{} = end_date) do
    if Date.compare(start_date, end_date) != :gt, do: :ok, else: {:error, :invalid_date_range}
  end
  defp validate_dates(_, _), do: {:error, :invalid_date_type}

  defp validate_grouping(g) when g in @valid_groupings, do: :ok
  defp validate_grouping(g), do: {:error, "invalid grouping: #{g}"}

  defp validate_status(s) when s in @valid_statuses, do: :ok
  defp validate_status(s), do: {:error, "invalid order_status: #{s}"}

  defp validate_format(f) when f in @valid_formats, do: :ok
  defp validate_format(f), do: {:error, "invalid output_format: #{f}"}

  defp fetch_sales_data(filters) do
    Logger.debug("Fetching sales data with filters: #{inspect(filters)}")
    []
  end

  defp group_by_period(rows, grouping) do
    Logger.debug("Grouping #{length(rows)} rows by #{grouping}")
    rows
  end

  defp maybe_include_taxes(rows, false), do: rows
  defp maybe_include_taxes(rows, true) do
    Enum.map(rows, &Map.put_new(&1, :tax_amount, 0.0))
  end

  defp maybe_include_refunds(rows, false), do: rows
  defp maybe_include_refunds(rows, true) do
    Enum.map(rows, &Map.put_new(&1, :refund_amount, 0.0))
  end

  defp render(report, "json"), do: {:ok, Jason.encode!(report)}
  defp render(report, "csv"), do: {:ok, to_csv(report)}
  defp render(report, "pdf"), do: {:ok, to_pdf(report)}

  defp to_csv(report) do
    Logger.debug("Serialising report #{report.tenant_id} to CSV")
    "tenant_id,generated_at\n#{report.tenant_id},#{report.generated_at}"
  end

  defp to_pdf(report) do
    Logger.debug("Serialising report #{report.tenant_id} to PDF")
    <<0x25, 0x50, 0x44, 0x46>>
  end
end
```
