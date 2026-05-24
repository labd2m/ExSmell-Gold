# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `ReportEngine` module (entire module)
- **Affected functions:** `fetch_sales_data/2`, `fetch_inventory_snapshot/1`, `format_as_csv/2`, `format_as_json/2`, `deliver_by_email/3`, `upload_to_s3/3`
- **Short explanation:** `ReportEngine` conflates three independent concerns — data fetching, output formatting, and delivery — into one module. Changes to a new data source, a new export format, or a new delivery channel each force modifications to this single module for entirely unrelated reasons.

---

```elixir
defmodule Reporting.ReportEngine do
  @moduledoc """
  Fetches report data, formats it into various output types, and delivers
  reports to their configured destinations.
  """

  require Logger

  alias Reporting.Repo
  alias Reporting.Sales.SaleRecord
  alias Reporting.Inventory.SnapshotRecord

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module is responsible for three
  # independent things: (1) fetching/querying data, (2) formatting output,
  # and (3) delivering the report. Each can change for completely different
  # reasons (new data source, new format requirement, new delivery mechanism).

  ## ────────────────────────────────────────────
  ## Reason to modify (1): Data sources / queries
  ## ────────────────────────────────────────────

  @doc "Retrieves aggregated sales data between two dates."
  def fetch_sales_data(date_from, date_to) do
    import Ecto.Query

    records =
      from(s in SaleRecord,
        where: s.sale_date >= ^date_from and s.sale_date <= ^date_to,
        select: %{
          product_id: s.product_id,
          product_name: s.product_name,
          quantity: sum(s.quantity),
          revenue: sum(s.revenue)
        },
        group_by: [s.product_id, s.product_name],
        order_by: [desc: sum(s.revenue)]
      )
      |> Repo.all()

    Logger.info("Fetched #{length(records)} sales rows (#{date_from}–#{date_to})")
    {:ok, records}
  end

  @doc "Retrieves the inventory snapshot for a given warehouse on today's date."
  def fetch_inventory_snapshot(warehouse_id) do
    import Ecto.Query

    records =
      from(s in SnapshotRecord,
        where: s.warehouse_id == ^warehouse_id and s.snapshot_date == ^Date.utc_today(),
        select: %{
          sku: s.sku,
          product_name: s.product_name,
          quantity_on_hand: s.quantity_on_hand,
          reorder_point: s.reorder_point,
          status: s.status
        }
      )
      |> Repo.all()

    Logger.info(
      "Fetched inventory snapshot for warehouse #{warehouse_id}: #{length(records)} items"
    )

    {:ok, records}
  end

  ## ────────────────────────────────────────────
  ## Reason to modify (2): Output format / layout
  ## ────────────────────────────────────────────

  @doc "Formats a list of report rows as a CSV binary."
  def format_as_csv(rows, headers) when is_list(rows) and is_list(headers) do
    header_line = Enum.join(headers, ",")

    data_lines =
      Enum.map(rows, fn row ->
        headers
        |> Enum.map(fn h -> Map.get(row, h, "") |> to_string() end)
        |> Enum.join(",")
      end)

    csv = Enum.join([header_line | data_lines], "\n")
    Logger.debug("CSV formatted: #{length(rows)} rows, #{length(headers)} columns")
    {:ok, csv}
  end

  @doc "Formats a list of report rows as a pretty-printed JSON binary."
  def format_as_json(rows, metadata \\ %{}) do
    payload = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: metadata,
      row_count: length(rows),
      data: rows
    }

    case Jason.encode(payload, pretty: true) do
      {:ok, json} ->
        Logger.debug("JSON formatted: #{length(rows)} rows")
        {:ok, json}

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end

  ## ────────────────────────────────────────────
  ## Reason to modify (3): Delivery / distribution
  ## ────────────────────────────────────────────

  @doc "Sends a formatted report to a recipient via email."
  def deliver_by_email(content, recipient_email, subject) do
    message = %{
      to: recipient_email,
      from: "reports@company.com",
      subject: subject,
      body: "Please find the attached report.",
      attachment: %{
        filename: "report_#{Date.utc_today()}.csv",
        content_type: "text/csv",
        data: content
      }
    }

    Logger.info("Delivering report via email to #{recipient_email}")
    {:ok, message}
  end

  @doc "Uploads a formatted report to an S3-compatible object store."
  def upload_to_s3(content, bucket, key_prefix) do
    object_key = "#{key_prefix}/#{Date.utc_today()}_report.csv"
    byte_size = byte_size(content)

    Logger.info("Uploading #{byte_size} bytes to s3://#{bucket}/#{object_key}")

    {:ok,
     %{
       bucket: bucket,
       key: object_key,
       size_bytes: byte_size,
       uploaded_at: DateTime.utc_now()
     }}
  end

  # VALIDATION: SMELL END
end
```
