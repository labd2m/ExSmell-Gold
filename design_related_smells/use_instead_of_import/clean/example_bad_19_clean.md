```elixir
defmodule Reporting.NumberHelpers do
  @moduledoc """
  Formatting and rounding helpers for numeric values in generated reports.
  """

  def format_currency(cents, symbol \\ "$") do
    "#{symbol}#{:erlang.float_to_binary(cents / 100, [{:decimals, 2}])}"
  end

  def format_percentage(ratio) when is_float(ratio) do
    pct = Float.round(ratio * 100, 2)
    "#{pct}%"
  end

  def round_to(value, places) when is_float(value) and is_integer(places) do
    Float.round(value, places)
  end

  def delta_label(current, previous) when previous == 0, do: "N/A"
  def delta_label(current, previous) do
    change = (current - previous) / previous * 100
    sign   = if change >= 0, do: "+", else: ""
    "#{sign}#{Float.round(change, 1)}%"
  end

  def sum_field(rows, field) when is_list(rows) and is_atom(field) do
    Enum.reduce(rows, 0, fn row, acc -> acc + Map.get(row, field, 0) end)
  end

  def avg_field(rows, field) when is_list(rows) and is_atom(field) and length(rows) > 0 do
    sum_field(rows, field) / length(rows)
  end

  def avg_field(_, _), do: 0

  defmacro __using__(_opts) do
    quote do
      import Reporting.NumberHelpers
      alias Reporting.DataSource

      @report_timezone "UTC"
      @decimal_places  2
    end
  end
end

defmodule Reporting.DataSource do
  @moduledoc "Stub: fetches raw transaction data for report generation."

  def fetch_transactions(account_id, %Date{} = from, %Date{} = to) do
    [
      %{date: from, amount_cents: 12_500, product: "Pro Plan", region: "US"},
      %{date: to,   amount_cents:  8_750, product: "Basic Plan", region: "EU"}
    ]
  end

  def fetch_refunds(account_id, %Date{} = from, %Date{} = to) do
    [%{date: from, amount_cents: 1_000, reason: "customer_request"}]
  end
end

defmodule Reporting.RevenueReport do
  use Reporting.NumberHelpers

  @moduledoc """
  Generates revenue summary reports for a given account and date range.
  Includes gross revenue, refunds, net revenue, and period-over-period delta.
  """

  defstruct [
    :account_id, :period_from, :period_to,
    :rows, :gross_cents, :refunds_cents, :net_cents,
    :generated_at, :timezone
  ]

  def generate(account_id, %{from: from, to: to} = _range) do
    transactions = DataSource.fetch_transactions(account_id, from, to)
    refunds      = DataSource.fetch_refunds(account_id, from, to)

    rows          = build_rows(transactions)
    gross_cents   = sum_field(rows, :amount_cents)
    refunds_cents = sum_field(refunds, :amount_cents)
    net_cents     = gross_cents - refunds_cents

    %__MODULE__{
      account_id:    account_id,
      period_from:   from,
      period_to:     to,
      rows:          rows,
      gross_cents:   gross_cents,
      refunds_cents: refunds_cents,
      net_cents:     net_cents,
      generated_at:  DateTime.utc_now(),
      timezone:      @report_timezone
    }
  end

  def summarise_by_period(%__MODULE__{rows: rows}, :monthly) do
    rows
    |> Enum.group_by(fn r -> {r.date.year, r.date.month} end)
    |> Enum.map(fn {{y, m}, group} ->
      %{
        period:     "#{y}-#{String.pad_leading(to_string(m), 2, "0")}",
        revenue:    format_currency(sum_field(group, :amount_cents)),
        avg_order:  format_currency(round(avg_field(group, :amount_cents)))
      }
    end)
  end

  def format_row(%{date: date, amount_cents: amt, product: prod, region: region}) do
    "#{Date.to_iso8601(date)} | #{String.pad_trailing(prod, 20)} | #{region} | #{format_currency(amt)}"
  end

  def totals(%__MODULE__{gross_cents: g, refunds_cents: r, net_cents: n}) do
    %{
      gross:    format_currency(g),
      refunds:  format_currency(r),
      net:      format_currency(n),
      margin:   format_percentage(if g > 0, do: n / g, else: 0.0)
    }
  end

  def render(%__MODULE__{} = report) do
    t = totals(report)
    header = "Revenue Report | #{report.period_from} → #{report.period_to} | TZ: #{report.timezone}\n"
    rows   = report.rows |> Enum.map(&format_row/1) |> Enum.join("\n")
    footer = "\nGross: #{t.gross}  Refunds: #{t.refunds}  Net: #{t.net}  Margin: #{t.margin}"
    header <> rows <> footer
  end

  defp build_rows(transactions), do: transactions
end
```
