```elixir
defmodule MyApp.ReportService do
  @moduledoc """
  Builds business reports, serialises them into various formats,
  and delivers the output to recipients via email.
  """

  alias MyApp.Repo
  alias MyApp.Sales.{Order, OrderItem}
  alias MyApp.Inventory.{Product, StockMovement}
  import Ecto.Query



  def build_sales_summary(from_date, to_date) do
    rows =
      from(o in Order,
        join: i in assoc(o, :items),
        where: o.inserted_at >= ^from_date and o.inserted_at <= ^to_date,
        where: o.status == :completed,
        group_by: i.sku,
        select: %{
          sku: i.sku,
          units_sold: sum(i.quantity),
          gross_revenue: sum(i.quantity * i.unit_price_cents),
          order_count: count(o.id, :distinct)
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        Map.update!(row, :gross_revenue, &Decimal.div(&1, 100))
      end)

    %{
      period: %{from: from_date, to: to_date},
      generated_at: DateTime.utc_now(),
      rows: rows,
      totals: %{
        units_sold: Enum.sum(Enum.map(rows, & &1.units_sold)),
        gross_revenue: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.gross_revenue))
      }
    }
  end

  def build_inventory_snapshot(warehouse_id) do
    movements =
      from(m in StockMovement,
        join: p in assoc(m, :product),
        where: m.warehouse_id == ^warehouse_id,
        group_by: [p.id, p.sku, p.name],
        select: %{
          product_id: p.id,
          sku: p.sku,
          name: p.name,
          on_hand: sum(m.delta),
          last_movement: max(m.inserted_at)
        }
      )
      |> Repo.all()

    %{
      warehouse_id: warehouse_id,
      snapshot_at: DateTime.utc_now(),
      rows: movements,
      out_of_stock: Enum.filter(movements, &(&1.on_hand <= 0))
    }
  end


  def render_csv(%{rows: rows} = _report, columns) when is_list(columns) do
    header = Enum.join(columns, ",")

    data_lines =
      Enum.map(rows, fn row ->
        columns
        |> Enum.map(fn col ->
          value = Map.get(row, String.to_existing_atom(col), "")
          escape_csv_field(value)
        end)
        |> Enum.join(",")
      end)

    ([header] ++ data_lines)
    |> Enum.join("\n")
  end

  def render_pdf(%{rows: rows, generated_at: ts} = report, title) do
    header_html = "<h1>#{title}</h1><p>Generated: #{DateTime.to_string(ts)}</p>"

    table_rows =
      Enum.map_join(rows, "\n", fn row ->
        cells = row |> Map.values() |> Enum.map_join("", &"<td>#{&1}</td>")
        "<tr>#{cells}</tr>"
      end)

    html = """
    <html>
    <head><style>
      body { font-family: sans-serif; font-size: 12px; }
      table { border-collapse: collapse; width: 100%; }
      th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; }
      th { background: #f0f0f0; }
    </style></head>
    <body>
      <table>
        <thead><tr>#{map_keys_to_headers(report)}</tr></thead>
        <tbody>#{table_rows}</tbody>
      </table>
    </body>
    </html>
    """

    MyApp.PdfRenderer.from_html(html)
  end

  defp escape_csv_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp escape_csv_field(value), do: to_string(value)

  defp map_keys_to_headers(%{rows: [first | _]}) do
    first |> Map.keys() |> Enum.map_join("", &"<th>#{&1}</th>")
  end

  defp map_keys_to_headers(_), do: ""


  @sender "reports@myapp.io"

  def deliver_report(recipient_email, subject, %{content: content, format: format}) do
    {filename, mime_type} =
      case format do
        :csv -> {"report.csv", "text/csv"}
        :pdf -> {"report.pdf", "application/pdf"}
      end

    %{
      from: @sender,
      to: recipient_email,
      subject: subject,
      text_body: "Please find your requested report attached.",
      attachments: [
        %{
          filename: filename,
          content_type: mime_type,
          body: content
        }
      ]
    }
    |> MyApp.Mailer.deliver()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, {:delivery_failed, reason}}
    end
  end

end
```
