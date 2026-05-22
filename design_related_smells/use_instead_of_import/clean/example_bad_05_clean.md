```elixir
defmodule Reporting.MathUtils do
  @moduledoc """
  Statistical and mathematical helpers used across reporting modules.
  """

  def mean([]), do: 0.0
  def mean(list), do: Enum.sum(list) / length(list)

  def median([]), do: 0.0
  def median(list) do
    sorted = Enum.sort(list)
    n      = length(sorted)

    if rem(n, 2) == 1 do
      Enum.at(sorted, div(n, 2)) * 1.0
    else
      mid = div(n, 2)
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end

  def percentage(part, total) when total == 0, do: 0.0
  def percentage(part, total), do: Float.round(part / total * 100, 2)

  def growth_rate(previous, current) when previous == 0, do: nil
  def growth_rate(previous, current) do
    Float.round((current - previous) / previous * 100, 2)
  end
end

defmodule Reporting.ChartHelpers do
  @moduledoc """
  ASCII and plain-text chart and table rendering utilities, shared across
  reporting modules via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Reporting.MathUtils  # propagates math dependency into every caller

      def bar_chart(data, opts \\ []) do
        max_val  = data |> Enum.map(fn {_, v} -> v end) |> Enum.max(fn -> 0 end)
        bar_len  = opts[:width] || 30
        label_w  = opts[:label_width] || 16

        Enum.map(data, fn {label, value} ->
          filled  = if max_val > 0, do: round(value / max_val * bar_len), else: 0
          bar     = String.duplicate("█", filled) <> String.duplicate("░", bar_len - filled)
          padded  = String.pad_trailing(to_string(label), label_w)
          "#{padded} #{bar} #{value}"
        end)
        |> Enum.join("\n")
      end

      def data_table(rows, headers) do
        col_widths =
          headers
          |> Enum.with_index()
          |> Enum.map(fn {h, i} ->
            max_val = Enum.map(rows, fn r -> String.length(to_string(Enum.at(r, i))) end) |> Enum.max(fn -> 0 end)
            max(String.length(to_string(h)), max_val)
          end)

        separator = col_widths |> Enum.map(&String.duplicate("-", &1 + 2)) |> Enum.join("+")
        header_row =
          headers
          |> Enum.zip(col_widths)
          |> Enum.map(fn {h, w} -> String.pad_trailing(to_string(h), w) end)
          |> Enum.join(" | ")

        data_rows =
          Enum.map(rows, fn row ->
            row
            |> Enum.zip(col_widths)
            |> Enum.map(fn {cell, w} -> String.pad_trailing(to_string(cell), w) end)
            |> Enum.join(" | ")
          end)

        ([header_row, separator] ++ data_rows) |> Enum.join("\n")
      end
    end
  end
end

defmodule Reporting.SalesReport do
  @moduledoc """
  Generates monthly and quarterly sales reports with trend analysis,
  product breakdowns, and region comparisons.
  """

  use Reporting.ChartHelpers

  @regions [:north, :south, :east, :west]

  def monthly_summary(sales_data, month, year) do
    totals_by_region =
      @regions
      |> Enum.map(fn region ->
        entries = Enum.filter(sales_data, &(&1.region == region))
        total   = Enum.reduce(entries, 0, &(&1.amount + &2))
        {region, total}
      end)

    grand_total = totals_by_region |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    rows =
      Enum.map(totals_by_region, fn {region, total} ->
        pct = percentage(total, grand_total)
        [String.upcase(to_string(region)), total, "#{pct}%"]
      end)

    """
    === Sales Report: #{month}/#{year} ===

    #{bar_chart(totals_by_region)}

    #{data_table(rows, ["Region", "Total ($)", "Share (%)"])}

    Grand Total: $#{grand_total}
    """
  end

  def quarterly_trend(monthly_totals) when is_list(monthly_totals) do
    avg = mean(monthly_totals)
    med = median(monthly_totals)

    rates =
      monthly_totals
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [prev, curr] -> growth_rate(prev, curr) end)

    avg_growth = if rates == [], do: nil, else: mean(rates)

    %{
      monthly_totals: monthly_totals,
      average:        avg,
      median:         med,
      growth_rates:   rates,
      avg_growth:     avg_growth
    }
  end

  def top_products(line_items, limit \\ 5) do
    line_items
    |> Enum.group_by(& &1.product_id)
    |> Enum.map(fn {product_id, items} ->
      {product_id, Enum.reduce(items, 0, &(&1.amount + &2))}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(limit)
  end
end
```
