```elixir
defmodule Reporting.RevenueReport do
  @moduledoc """
  Generates revenue summaries and breakdowns for finance reporting.
  Supports monthly and quarterly aggregations over transaction data.
  """

  alias Reporting.Repo
  alias Reporting.Transaction

  @doc """
  Generates a revenue summary for a given year and month (1–12).
  Returns a map with total revenue and transaction count.
  """
  def monthly_summary(year, month) when month in 1..12 do
    start_date = Date.new!(year, month, 1)
    end_date = Date.end_of_month(start_date)

    transactions =
      Repo.all_by(Transaction,
        status: :settled,
        inserted_after: start_date,
        inserted_before: end_date
      )

    revenue_cents =
      transactions
      |> Enum.reject(&(&1.type == :refund))
      |> Enum.reduce(0, fn txn, acc -> acc + txn.amount_cents end)

    revenue_dollars = revenue_cents / 100.0

    %{
      period: "#{year}-#{String.pad_leading("#{month}", 2, "0")}",
      total_revenue: Float.round(revenue_dollars, 2),
      transaction_count: length(transactions),
      currency: "USD"
    }
  end

  @doc """
  Generates a revenue summary for a given year and quarter (1–4).
  Returns a map with total revenue and transaction count.
  """
  def quarterly_summary(year, quarter) when quarter in 1..4 do
    first_month = (quarter - 1) * 3 + 1
    last_month = first_month + 2

    start_date = Date.new!(year, first_month, 1)
    end_date = Date.new!(year, last_month, 1) |> Date.end_of_month()

    transactions =
      Repo.all_by(Transaction,
        status: :settled,
        inserted_after: start_date,
        inserted_before: end_date
      )

    revenue_cents =
      transactions
      |> Enum.reject(&(&1.type == :refund))
      |> Enum.reduce(0, fn txn, acc -> acc + txn.amount_cents end)

    revenue_dollars = revenue_cents / 100.0

    %{
      period: "#{year}-Q#{quarter}",
      total_revenue: Float.round(revenue_dollars, 2),
      transaction_count: length(transactions),
      currency: "USD"
    }
  end

  @doc """
  Returns the year-to-date revenue totals broken down by month.
  """
  def ytd_breakdown(year) do
    1..Date.utc_today().month
    |> Enum.map(fn month -> monthly_summary(year, month) end)
  end

  @doc """
  Compares revenue between two months, returning a percent change.
  """
  def month_over_month_change(year, month) do
    {prev_year, prev_month} =
      if month == 1, do: {year - 1, 12}, else: {year, month - 1}

    current = monthly_summary(year, month).total_revenue
    previous = monthly_summary(prev_year, prev_month).total_revenue

    change =
      if previous == 0.0 do
        nil
      else
        Float.round((current - previous) / previous * 100, 2)
      end

    %{current_revenue: current, previous_revenue: previous, percent_change: change}
  end
end
```
