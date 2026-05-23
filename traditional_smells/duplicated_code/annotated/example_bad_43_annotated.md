# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Reporting.RevenueReport.monthly_summary/2` and `Reporting.RevenueReport.quarterly_summary/2` |
| **Affected functions** | `monthly_summary/2`, `quarterly_summary/2` |
| **Short explanation** | Both functions duplicate the same pipeline for fetching transactions, filtering by account tier, computing per-currency totals, and building the report struct. A new account tier or a new currency operation must be added in both places. |

```elixir
defmodule Reporting.RevenueReport do
  @moduledoc """
  Generates revenue summary reports for internal finance dashboards.
  Supports monthly and quarterly aggregations across account tiers.
  """

  alias Reporting.{Transaction, ReportResult, Repo}

  @premium_tiers [:enterprise, :business, :professional]

  # ---------------------------------------------------------------------------
  # Monthly summary
  # ---------------------------------------------------------------------------

  @doc """
  Returns a revenue summary for the given year/month combination.
  Filters out free-tier accounts that have zero contractual revenue.
  """
  def monthly_summary(year, month) when month in 1..12 do
    {from, to} = month_range(year, month)

    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the entire pipeline—fetching
    # transactions, filtering premium tiers, grouping by currency, building
    # totals—is copied verbatim into quarterly_summary/2. Any change to the
    # aggregation logic must be applied in both functions.
    transactions =
      Repo.list_transactions(from, to)
      |> Enum.filter(fn t -> t.account_tier in @premium_tiers end)

    gross_by_currency =
      transactions
      |> Enum.group_by(& &1.currency)
      |> Map.new(fn {currency, txns} ->
        total = Enum.reduce(txns, 0, fn t, acc -> acc + t.amount_cents end)
        {currency, total}
      end)

    refunded_by_currency =
      transactions
      |> Enum.filter(& &1.refunded?)
      |> Enum.group_by(& &1.currency)
      |> Map.new(fn {currency, txns} ->
        total = Enum.reduce(txns, 0, fn t, acc -> acc + t.refund_amount_cents end)
        {currency, total}
      end)

    net_by_currency =
      Map.new(gross_by_currency, fn {currency, gross} ->
        refunded = Map.get(refunded_by_currency, currency, 0)
        {currency, gross - refunded}
      end)

    result = %ReportResult{
      period:              :monthly,
      from:                from,
      to:                  to,
      transaction_count:   length(transactions),
      gross_by_currency:   gross_by_currency,
      refunded_by_currency: refunded_by_currency,
      net_by_currency:     net_by_currency,
      generated_at:        DateTime.utc_now()
    }
    # VALIDATION: SMELL END

    {:ok, result}
  end

  # ---------------------------------------------------------------------------
  # Quarterly summary
  # ---------------------------------------------------------------------------

  @doc """
  Returns a revenue summary for the given year/quarter (quarter in 1..4).
  Filters out free-tier accounts that have zero contractual revenue.
  """
  def quarterly_summary(year, quarter) when quarter in 1..4 do
    {from, to} = quarter_range(year, quarter)

    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the identical aggregation pipeline
    # from monthly_summary/2 is reproduced here without abstraction. The two
    # blocks must always be kept in sync.
    transactions =
      Repo.list_transactions(from, to)
      |> Enum.filter(fn t -> t.account_tier in @premium_tiers end)

    gross_by_currency =
      transactions
      |> Enum.group_by(& &1.currency)
      |> Map.new(fn {currency, txns} ->
        total = Enum.reduce(txns, 0, fn t, acc -> acc + t.amount_cents end)
        {currency, total}
      end)

    refunded_by_currency =
      transactions
      |> Enum.filter(& &1.refunded?)
      |> Enum.group_by(& &1.currency)
      |> Map.new(fn {currency, txns} ->
        total = Enum.reduce(txns, 0, fn t, acc -> acc + t.refund_amount_cents end)
        {currency, total}
      end)

    net_by_currency =
      Map.new(gross_by_currency, fn {currency, gross} ->
        refunded = Map.get(refunded_by_currency, currency, 0)
        {currency, gross - refunded}
      end)

    result = %ReportResult{
      period:               :quarterly,
      from:                 from,
      to:                   to,
      transaction_count:    length(transactions),
      gross_by_currency:    gross_by_currency,
      refunded_by_currency: refunded_by_currency,
      net_by_currency:      net_by_currency,
      generated_at:         DateTime.utc_now()
    }
    # VALIDATION: SMELL END

    {:ok, result}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp month_range(year, month) do
    {:ok, from} = Date.new(year, month, 1)
    to = Date.end_of_month(from)
    {DateTime.new!(from, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(to,   ~T[23:59:59], "Etc/UTC")}
  end

  defp quarter_range(year, quarter) do
    first_month = (quarter - 1) * 3 + 1
    last_month  = first_month + 2
    {:ok, from_date} = Date.new(year, first_month, 1)
    {:ok, to_date}   = Date.new(year, last_month, Date.days_in_month(Date.new!(year, last_month, 1)))
    {DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(to_date,   ~T[23:59:59], "Etc/UTC")}
  end
end
```
