```elixir
defmodule Reporting.SalesAggregator do
  @moduledoc """
  Aggregates sales transactions into period summaries for the reporting dashboard.

  Supports grouping by `:day`, `:week`, or `:month`, optional refund inclusion,
  and multi-currency normalization.
  """

  alias Reporting.CurrencyConverter
  alias Reporting.TransactionStore

  @supported_groups ~w(day week month)a
  @base_currency "USD"

  @doc """
  Produces an aggregated sales summary for the given date range and filters.

  `period` is a map with `:from` and `:to` `Date` values.

  `filters` may contain:
    - `:group_by`        — `:day`, `:week`, or `:month`
    - `:currency`        — ISO 4217 code for output amounts
    - `:include_refunds` — boolean; when `true` refunds are netted in totals
  """
  def summarize_period(period, filters) do
    group_by        = filters[:group_by]
    currency        = filters[:currency]
    include_refunds = filters[:include_refunds]

    effective_group    = if group_by in @supported_groups, do: group_by, else: :month
    effective_currency = currency || @base_currency

    transactions = TransactionStore.fetch_range(period.from, period.to)

    transactions
    |> maybe_exclude_refunds(include_refunds)
    |> group_transactions(effective_group)
    |> Enum.map(fn {bucket, txns} ->
      gross   = sum_amounts(txns, :gross, effective_currency)
      net     = sum_amounts(txns, :net,   effective_currency)
      count   = length(txns)

      %{
        bucket:   bucket,
        currency: effective_currency,
        gross:    gross,
        net:      net,
        count:    count,
        average:  if(count > 0, do: Float.round(net / count, 2), else: 0.0)
      }
    end)
  end

  @doc """
  Renders summary rows as a CSV string for spreadsheet export.
  """
  def to_csv(rows) do
    header = "bucket,currency,gross,net,count,average\n"

    body =
      Enum.map_join(rows, "\n", fn row ->
        "#{row.bucket},#{row.currency},#{row.gross},#{row.net},#{row.count},#{row.average}"
      end)

    header <> body
  end

  ## Private

  defp maybe_exclude_refunds(txns, true),  do: txns
  defp maybe_exclude_refunds(txns, _),     do: Enum.reject(txns, & &1.type == :refund)

  defp group_transactions(txns, :day),   do: Enum.group_by(txns, & Date.to_string(&1.date))
  defp group_transactions(txns, :week),  do: Enum.group_by(txns, &week_label(&1.date))
  defp group_transactions(txns, :month), do: Enum.group_by(txns, &month_label(&1.date))

  defp sum_amounts(txns, field, currency) do
    txns
    |> Enum.map(fn txn ->
      CurrencyConverter.convert(Map.fetch!(txn, field), txn.currency, currency)
    end)
    |> Enum.sum()
    |> Float.round(2)
  end

  defp week_label(date) do
    {year, week} = Date.to_iso_weeks(date)
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  defp month_label(date), do: "#{date.year}-#{String.pad_leading(Integer.to_string(date.month), 2, "0")}"
end
```
