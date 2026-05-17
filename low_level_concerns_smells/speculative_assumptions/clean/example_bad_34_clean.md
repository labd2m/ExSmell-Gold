```elixir
defmodule Reporting.CsvImporter do
  @moduledoc """
  Imports sales report CSV exports from third-party retail partners.
  Each CSV file has a header row followed by data rows.

  Expected columns (order may vary by partner):
    order_id, partner_id, product_sku, quantity, unit_price,
    discount_pct, tax_amount, shipping_cost, total_amount, order_date
  """

  require Logger

  @required_columns ~w(order_id partner_id product_sku quantity unit_price total_amount order_date)

  def import_file(path) do
    rows =
      path
      |> File.stream!()
      |> CSV.decode!(headers: false)
      |> Enum.to_list()

    case rows do
      [header | data_rows] ->
        with :ok <- validate_headers(header) do
          records = Enum.map(data_rows, &map_row(&1, header))
          {:ok, records}
        end

      [] ->
        {:error, :empty_file}
    end
  end

  defp validate_headers(header) do
    missing = Enum.reject(@required_columns, &(&1 in header))

    if missing == [] do
      :ok
    else
      {:error, {:missing_columns, missing}}
    end
  end

  defp map_row(row, header) do
    col = fn name ->
      idx = Enum.find_index(header, &(&1 == name))
      Enum.at(row, idx)
    end

    %{
      order_id:      col.("order_id"),
      partner_id:    col.("partner_id"),
      product_sku:   col.("product_sku"),
      quantity:      col.("quantity")      |> parse_integer(),
      unit_price:    col.("unit_price")    |> parse_decimal(),
      discount_pct:  col.("discount_pct")  |> parse_decimal(),
      tax_amount:    col.("tax_amount")    |> parse_decimal(),
      shipping_cost: col.("shipping_cost") |> parse_decimal(),
      total_amount:  col.("total_amount")  |> parse_decimal(),
      order_date:    col.("order_date")    |> parse_date()
    }
  end

  def aggregate_by_partner(records) do
    records
    |> Enum.group_by(& &1.partner_id)
    |> Enum.map(fn {partner, rows} ->
      total    = rows |> Enum.map(& &1.total_amount) |> Enum.reject(&is_nil/1) |> Enum.sum()
      quantity = rows |> Enum.map(& &1.quantity)     |> Enum.reject(&is_nil/1) |> Enum.sum()

      %{partner_id: partner, total_revenue: total, total_units: quantity, order_count: length(rows)}
    end)
  end

  def top_products(records, n \\ 10) do
    records
    |> Enum.group_by(& &1.product_sku)
    |> Enum.map(fn {sku, rows} ->
      qty = rows |> Enum.map(& &1.quantity) |> Enum.reject(&is_nil/1) |> Enum.sum()
      {sku, qty}
    end)
    |> Enum.sort_by(fn {_sku, qty} -> qty end, :desc)
    |> Enum.take(n)
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(str) do
    case Float.parse(String.trim(str)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(String.trim(str)) do
      {:ok, date} -> date
      _           -> nil
    end
  end
end
```
