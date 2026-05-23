```elixir
defmodule Reporting.OrderExporter do
  @moduledoc """
  Exports sales order data to CSV for business intelligence pipelines
  and finance reconciliation workflows. Supports date range filtering,
  channel filtering, and configurable column sets.
  """

  alias Reporting.{ExportJob, ColumnConfig}
  alias Commerce.{SalesOrder, Customer, Address}
  alias NimbleCSV.RFC4180, as: CSV

  @batch_size 250

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Runs an export job, writing CSV rows to the configured output stream.
  Returns `{:ok, row_count}` on success.
  """
  @spec run(ExportJob.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(%ExportJob{} = job) do
    columns   = ColumnConfig.resolve(job.column_set)
    header    = Enum.map(columns, & &1.label)
    stream    = order_stream(job)

    row_count =
      stream
      |> Stream.map(&serialize_order_row/1)
      |> Stream.map(&apply_column_filter(&1, columns))
      |> Stream.chunk_every(@batch_size)
      |> Stream.map(&CSV.dump_to_iodata/1)
      |> Enum.reduce(0, fn chunk, acc ->
        ExportJob.write_chunk(job, chunk)
        acc + length(chunk)
      end)

    ExportJob.write_header(job, CSV.dump_to_iodata([header]))
    {:ok, row_count}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp serialize_order_row(order) do
    customer    = SalesOrder.get_customer(order)
    address     = SalesOrder.get_shipping_address(order)
    line_items  = SalesOrder.list_line_items(order)
    fulfilment  = SalesOrder.fulfilment_status(order)
    coupon      = SalesOrder.applied_coupon(order)

    item_count  = Enum.count(line_items)
    sku_list    = line_items |> Enum.map(& &1.sku) |> Enum.join("|")

    %{
      order_id:          order.id,
      order_number:      order.number,
      channel:           order.channel,
      placed_at:         format_timestamp(order.placed_at),
      customer_id:       customer.id,
      customer_email:    customer.email,
      customer_name:     Customer.display_name(customer),
      shipping_country:  Address.iso_country(address),
      shipping_region:   address.region_code,
      currency:          order.currency,
      subtotal:          decimal_to_string(order.subtotal),
      discount_total:    decimal_to_string(order.discount_total),
      tax_total:         decimal_to_string(order.tax_total),
      grand_total:       decimal_to_string(order.grand_total),
      payment_status:    order.payment_status,
      fulfilment_status: fulfilment,
      item_count:        item_count,
      skus:              sku_list,
      coupon_code:       if(coupon, do: coupon.code, else: "")
    }
  end

  defp order_stream(job) do
    SalesOrder.stream_by_date_range(
      job.date_from,
      job.date_to,
      channel: job.channel_filter,
      batch_size: @batch_size
    )
  end

  defp apply_column_filter(row_map, columns) do
    Enum.map(columns, fn col ->
      row_map |> Map.get(col.key, "") |> to_string()
    end)
  end

  defp format_timestamp(nil), do: ""
  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%SZ")
  end

  defp decimal_to_string(%Decimal{} = d) do
    d |> Decimal.round(2) |> Decimal.to_string(:normal)
  end
  defp decimal_to_string(nil), do: ""
end
```
