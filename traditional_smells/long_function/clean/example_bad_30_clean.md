```elixir
defmodule Reporting.SalesReport do
  @moduledoc """
  Generates periodic sales reports with KPIs, regional
  breakdowns, and product performance summaries.
  """

  require Logger

  alias Reporting.{OrderStore, RefundStore, ProductStore, Storage}

  @csv_header "date,region,product_id,product_name,units_sold,revenue,refunds,net_revenue,aov\n"

  def generate(params, opts \\ []) do
    upload    = Keyword.get(opts, :upload, true)
    requester = Keyword.get(opts, :requested_by, "system")

    # 1. Validate date range
    with {:ok, date_from} <- Date.from_iso8601(params["date_from"]),
         {:ok, date_to}   <- Date.from_iso8601(params["date_to"]) do

      if Date.compare(date_from, date_to) == :gt do
        {:error, :invalid_date_range}
      else
        days = Date.diff(date_to, date_from) + 1

        if days > 366 do
          {:error, :range_too_large}
        else
          Logger.info("#{requester} generating sales report #{date_from}..#{date_to}")

          # 2. Fetch raw orders
          orders = OrderStore.list_completed(date_from, date_to)

          if orders == [] do
            {:ok, %{report: [], csv: @csv_header, uploaded: false}}
          else
            # 3. Fetch refunds for the same window
            refund_index =
              date_from
              |> RefundStore.list_by_range(date_to)
              |> Enum.reduce(%{}, fn r, acc ->
                Map.update(acc, r.order_id, r.amount, &(&1 + r.amount))
              end)

            # 4. Fetch product catalogue for name lookup
            product_map =
              orders
              |> Enum.flat_map(& &1.line_items)
              |> Enum.map(& &1.product_id)
              |> Enum.uniq()
              |> Enum.map(fn pid ->
                product = ProductStore.get(pid)
                {pid, product}
              end)
              |> Map.new()

            # 5. Build grouped data: {date, region, product_id} → aggregates
            grouped =
              Enum.reduce(orders, %{}, fn order, acc ->
                region = order.shipping_address.region || "UNKNOWN"
                date   = DateTime.to_date(order.completed_at)

                Enum.reduce(order.line_items, acc, fn item, inner ->
                  key = {date, region, item.product_id}

                  Map.update(inner, key, %{units: item.quantity, revenue: item.total},
                    fn existing ->
                      %{existing |
                        units:   existing.units + item.quantity,
                        revenue: existing.revenue + item.total
                      }
                    end)
                end)
              end)

            # 6. Compute KPIs and build report rows
            report_rows =
              grouped
              |> Enum.map(fn {{date, region, product_id}, agg} ->
                refunded    = Map.get(refund_index, product_id, 0.0)
                net_revenue = Float.round(agg.revenue - refunded, 2)
                aov         = if agg.units > 0, do: Float.round(agg.revenue / agg.units, 2), else: 0.0

                product_name =
                  case Map.get(product_map, product_id) do
                    nil     -> "Unknown"
                    product -> product.name
                  end

                %{
                  date:        Date.to_iso8601(date),
                  region:      region,
                  product_id:  product_id,
                  product_name: product_name,
                  units_sold:  agg.units,
                  revenue:     agg.revenue,
                  refunds:     refunded,
                  net_revenue: net_revenue,
                  aov:         aov
                }
              end)
              |> Enum.sort_by(&{&1.date, &1.region, &1.product_id})

            # 7. Serialise to CSV
            csv_rows =
              Enum.map(report_rows, fn row ->
                "#{row.date},#{row.region},#{row.product_id}," <>
                  "\"#{row.product_name}\",#{row.units_sold}," <>
                  "#{row.revenue},#{row.refunds},#{row.net_revenue},#{row.aov}\n"
              end)

            csv_content = @csv_header <> Enum.join(csv_rows)

            # 8. Upload to storage if requested
            uploaded =
              if upload do
                filename = "sales_#{date_from}_#{date_to}_#{:os.system_time(:millisecond)}.csv"

                case Storage.upload("reports/sales/#{filename}", csv_content, content_type: "text/csv") do
                  {:ok, url} ->
                    Logger.info("Sales report uploaded to #{url}")
                    url

                  {:error, reason} ->
                    Logger.error("Report upload failed: #{inspect(reason)}")
                    nil
                end
              else
                nil
              end

            {:ok, %{report: report_rows, csv: csv_content, uploaded: uploaded != nil, url: uploaded}}
          end
        end
      end
    else
      {:error, _} -> {:error, :invalid_date_format}
    end
  end
end
```
