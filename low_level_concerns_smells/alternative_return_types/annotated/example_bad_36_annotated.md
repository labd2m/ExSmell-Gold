# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Reporting.SalesReport.generate/2`, around the `opts[:output]` branching
- **Affected function(s):** `generate/2`
- **Short explanation:** The function returns a CSV binary, a list of row maps, or an `%Xlsxir.Workbook{}` struct depending on the `:output` option. These types are completely incompatible, so any caller must know the option to handle the result.

---

```elixir
defmodule Reporting.SalesReport do
  @moduledoc """
  Generates sales performance reports for a given date range.
  Supports multiple output formats for download and programmatic consumption.
  """

  alias Reporting.Repo
  alias Reporting.Schema.{Order, OrderItem}

  import Ecto.Query

  @doc """
  Generates a sales report for the given date range.

  ## Arguments

    * `date_range` — A `Date.Range.t()` specifying the period.
    * `opts` — Keyword list of options.

  ## Options

    * `:group_by` — Group results by `:day`, `:week`, or `:month`.
      Defaults to `:day`.
    * `:output` — Format of the return value:
      - `:rows` (default) — Returns `[%{date: Date.t(), revenue: Decimal.t(), orders: integer()}]`
      - `:csv` — Returns a CSV-formatted binary string.
      - `:xlsx` — Returns an `%Xlsxir.Workbook{}` struct ready to be written to disk.

  ## Examples

      iex> generate(Date.range(~D[2024-01-01], ~D[2024-01-31]))
      [%{date: ~D[2024-01-01], revenue: #Decimal<1240.00>, orders: 14}, ...]

      iex> generate(Date.range(~D[2024-01-01], ~D[2024-01-31]), output: :csv)
      "date,revenue,orders\n2024-01-01,1240.00,14\n..."

      iex> generate(Date.range(~D[2024-01-01], ~D[2024-01-31]), output: :xlsx)
      %Xlsxir.Workbook{sheets: [...]}

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because the :output option changes the return
  # VALIDATION: type from a list of maps, to a binary (CSV), to an Xlsxir
  # VALIDATION: workbook struct. These are structurally unrelated types, and
  # VALIDATION: callers must branch on the option value they passed in to safely
  # VALIDATION: handle the result — defeating the purpose of a single function.
  def generate(%Date.Range{} = date_range, opts \\ []) do
    group_by = Keyword.get(opts, :group_by, :day)
    output = Keyword.get(opts, :output, :rows)

    rows = fetch_aggregated_rows(date_range, group_by)

    case output do
      :csv ->
        header = "date,revenue,orders\n"

        body =
          Enum.map_join(rows, "\n", fn row ->
            "#{row.date},#{Decimal.to_string(row.revenue)},#{row.orders}"
          end)

        header <> body

      :xlsx ->
        sheet_rows =
          [["Date", "Revenue", "Orders"]] ++
            Enum.map(rows, fn row ->
              [Date.to_iso8601(row.date), Decimal.to_float(row.revenue), row.orders]
            end)

        Xlsxir.new_workbook()
        |> Xlsxir.add_sheet("Sales", sheet_rows)

      _ ->
        rows
    end
  end
  # VALIDATION: SMELL END

  defp fetch_aggregated_rows(%Date.Range{first: from, last: to}, :day) do
    Order
    |> where([o], o.placed_at >= ^from and o.placed_at <= ^to)
    |> where([o], o.status == :completed)
    |> group_by([o], fragment("DATE(placed_at)"))
    |> select([o], %{
      date: fragment("DATE(placed_at)"),
      revenue: sum(o.total_amount),
      orders: count(o.id)
    })
    |> order_by([o], asc: fragment("DATE(placed_at)"))
    |> Repo.all()
  end

  defp fetch_aggregated_rows(%Date.Range{first: from, last: to}, :month) do
    Order
    |> where([o], o.placed_at >= ^from and o.placed_at <= ^to)
    |> where([o], o.status == :completed)
    |> group_by([o], fragment("DATE_TRUNC('month', placed_at)"))
    |> select([o], %{
      date: fragment("DATE_TRUNC('month', placed_at)::date"),
      revenue: sum(o.total_amount),
      orders: count(o.id)
    })
    |> order_by([o], asc: fragment("DATE_TRUNC('month', placed_at)"))
    |> Repo.all()
  end

  defp fetch_aggregated_rows(date_range, :week) do
    fetch_aggregated_rows(date_range, :day)
    |> Enum.group_by(fn row -> iso_week(row.date) end)
    |> Enum.map(fn {week_key, rows} ->
      %{
        date: hd(rows).date,
        week: week_key,
        revenue: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.revenue, &2)),
        orders: Enum.sum(Enum.map(rows, & &1.orders))
      }
    end)
    |> Enum.sort_by(& &1.date, Date)
  end

  defp iso_week(date), do: "#{date.year}-W#{String.pad_leading("#{Date.day_of_week(date)}", 2, "0")}"

  @doc """
  Returns the top N products by revenue in the given date range.
  """
  def top_products(%Date.Range{first: from, last: to}, limit \\ 10) do
    OrderItem
    |> join(:inner, [oi], o in Order, on: oi.order_id == o.id)
    |> where([_oi, o], o.placed_at >= ^from and o.placed_at <= ^to)
    |> where([_oi, o], o.status == :completed)
    |> group_by([oi, _o], oi.product_id)
    |> select([oi, _o], %{product_id: oi.product_id, revenue: sum(fragment("? * ?", oi.quantity, oi.unit_price))})
    |> order_by([oi, _o], desc: sum(fragment("? * ?", oi.quantity, oi.unit_price)))
    |> limit(^limit)
    |> Repo.all()
  end
end
```
