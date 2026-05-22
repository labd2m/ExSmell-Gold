```elixir
defmodule Reporting.SalesExporter do
  @moduledoc """
  Generates and persists sales reports for a given date range.

  Reports are serialised to CSV, uploaded to object storage,
  and a signed download URL is returned to the caller. Export
  behaviour (bucket, retention, row cap) is governed by
  application configuration.
  """

  require Logger

  @storage_bucket     Application.fetch_env!(:reporting, :export_storage_bucket)
  @report_ttl_days    Application.fetch_env!(:reporting, :report_ttl_days)
  @max_rows_per_export Application.fetch_env!(:reporting, :max_rows_per_export)

  @csv_delimiter ","
  @date_format   "{YYYY}-{0M}-{0D}"

  @type date_range :: %{from: Date.t(), to: Date.t()}
  @type export_result :: {:ok, %{url: String.t(), row_count: integer()}} | {:error, String.t()}

  @spec export_sales_report(String.t(), date_range()) :: export_result()
  def export_sales_report(tenant_id, %{from: from, to: to} = range) do
    Logger.info("Starting sales export",
      tenant_id: tenant_id,
      from: Date.to_string(from),
      to: Date.to_string(to)
    )

    with {:ok, rows}      <- fetch_sales_data(tenant_id, range),
         {:ok, truncated} <- apply_row_cap(rows),
         {:ok, csv}       <- encode_csv(truncated),
         {:ok, key}       <- build_storage_key(tenant_id, range),
         {:ok, url}       <- write_to_storage(key, csv) do
      Logger.info("Export completed",
        tenant_id: tenant_id,
        row_count: length(truncated),
        bucket: @storage_bucket,
        url: url
      )

      {:ok, %{url: url, row_count: length(truncated)}}
    else
      {:error, reason} ->
        Logger.error("Export failed", tenant_id: tenant_id, reason: reason)
        {:error, reason}
    end
  end

  @spec list_recent_exports(String.t()) :: {:ok, [map()]}
  def list_recent_exports(tenant_id) do
    prefix = "exports/#{tenant_id}/"
    Reporting.StorageAdapter.list_objects(@storage_bucket, prefix: prefix)
  end

  defp fetch_sales_data(tenant_id, %{from: from, to: to}) do
    Reporting.SalesQuery.run(%{
      tenant_id: tenant_id,
      date_from: from,
      date_to:   to
    })
  end

  defp apply_row_cap(rows) when length(rows) > @max_rows_per_export do
    Logger.warn("Row cap applied", cap: @max_rows_per_export, total: length(rows))
    {:ok, Enum.take(rows, @max_rows_per_export)}
  end

  defp apply_row_cap(rows), do: {:ok, rows}

  defp encode_csv([]), do: {:ok, csv_header()}

  defp encode_csv(rows) do
    header = csv_header()

    lines =
      Enum.map(rows, fn row ->
        [
          row.order_id,
          row.customer_id,
          to_string(row.amount),
          row.currency,
          Date.to_string(row.sale_date),
          row.status
        ]
        |> Enum.join(@csv_delimiter)
      end)

    {:ok, Enum.join([header | lines], "\n")}
  end

  defp csv_header do
    ["order_id", "customer_id", "amount", "currency", "sale_date", "status"]
    |> Enum.join(@csv_delimiter)
  end

  defp build_storage_key(tenant_id, %{from: from, to: to}) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    key       = "exports/#{tenant_id}/#{Date.to_string(from)}_#{Date.to_string(to)}_#{timestamp}.csv"
    {:ok, key}
  end

  defp write_to_storage(key, content) do
    metadata = build_metadata(key, content)

    case Reporting.StorageAdapter.put_object(@storage_bucket, key, content, metadata) do
      {:ok, _etag} ->
        signed_url = Reporting.StorageAdapter.presign_url(
          @storage_bucket,
          key,
          ttl_seconds: @report_ttl_days * 86_400
        )
        {:ok, signed_url}

      {:error, reason} ->
        {:error, "Storage write failed: #{reason}"}
    end
  end

  defp build_metadata(key, content) do
    %{
      "Content-Type"        => "text/csv",
      "Content-Length"      => byte_size(content) |> to_string(),
      "x-amz-meta-bucket"   => @storage_bucket,
      "x-amz-meta-ttl-days" => to_string(@report_ttl_days),
      "x-amz-meta-key"      => key
    }
  end
end
```
