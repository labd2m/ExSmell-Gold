```elixir
defmodule MyApp.Reporting.ReportBuilder do
  @moduledoc """
  Generates financial and operational reports for internal dashboards
  and scheduled exports. Reports can be rendered as maps, CSV strings,
  or streamed directly to S3.
  """

  alias MyApp.Repo
  alias MyApp.Billing.Invoice
  alias MyApp.Accounts.Account
  import Ecto.Query

  require Logger

  @doc """
  Returns a list of accounts with overdue invoices.
  Optionally accepts a `days_overdue` threshold (default 30).
  """
  def overdue_accounts(days_overdue \\ 30) do
    cutoff = Date.add(Date.utc_today(), -days_overdue)

    Invoice
    |> where([i], i.status == :pending and i.due_date < ^cutoff)
    |> join(:inner, [i], a in Account, on: a.id == i.account_id)
    |> select([i, a], %{account: a, invoice: i, overdue_days: fragment("CURRENT_DATE - ?", i.due_date)})
    |> Repo.all()
  end

  # Builds a revenue summary report for a given date range.
  #
  # Parameters:
  #   date_from - %Date{} representing the start of the reporting period (inclusive).
  #   date_to   - %Date{} representing the end of the reporting period (inclusive).
  #
  # The report aggregates paid invoice totals grouped by month, with sub-totals
  # per account tier (starter, professional, enterprise). Each row includes:
  #   - :month         (string, "YYYY-MM")
  #   - :tier          (atom)
  #   - :invoice_count (integer)
  #   - :gross_revenue (float)
  #   - :tax_collected (float)
  #   - :net_revenue   (float)
  #
  # Returns {:ok, report} where report is a list of the above row maps,
  # ordered by month ascending then tier alphabetically.
  def build_revenue_report(%Date{} = date_from, %Date{} = date_to) do
    with :ok <- validate_date_range(date_from, date_to) do
      rows =
        Invoice
        |> where([i], i.status == :paid)
        |> where([i], i.period_start >= ^date_from and i.period_end <= ^date_to)
        |> join(:inner, [i], a in Account, on: a.id == i.account_id)
        |> group_by([i, a], [
          fragment("TO_CHAR(?, 'YYYY-MM')", i.period_start),
          a.tier
        ])
        |> select([i, a], %{
          month: fragment("TO_CHAR(?, 'YYYY-MM')", i.period_start),
          tier: a.tier,
          invoice_count: count(i.id),
          gross_revenue: sum(i.total),
          tax_collected: sum(i.tax),
          net_revenue: sum(i.subtotal)
        })
        |> order_by([i, a], [
          asc: fragment("TO_CHAR(?, 'YYYY-MM')", i.period_start),
          asc: a.tier
        ])
        |> Repo.all()

      {:ok, rows}
    end
  end

  @doc """
  Exports a revenue report to CSV format.

  Accepts the same `date_from` and `date_to` parameters as
  `build_revenue_report/2` and returns `{:ok, csv_string}`.
  """
  def export_revenue_csv(%Date{} = date_from, %Date{} = date_to) do
    with {:ok, rows} <- build_revenue_report(date_from, date_to) do
      header = "month,tier,invoice_count,gross_revenue,tax_collected,net_revenue\n"

      body =
        rows
        |> Enum.map(fn row ->
          "#{row.month},#{row.tier},#{row.invoice_count}," <>
            "#{row.gross_revenue},#{row.tax_collected},#{row.net_revenue}"
        end)
        |> Enum.join("\n")

      {:ok, header <> body}
    end
  end

  @doc """
  Returns a breakdown of new account signups grouped by day within a date range.
  """
  def signup_report(%Date{} = date_from, %Date{} = date_to) do
    rows =
      Account
      |> where([a], fragment("DATE(?)", a.inserted_at) >= ^date_from)
      |> where([a], fragment("DATE(?)", a.inserted_at) <= ^date_to)
      |> group_by([a], fragment("DATE(?)", a.inserted_at))
      |> select([a], %{
        date: fragment("DATE(?)", a.inserted_at),
        count: count(a.id)
      })
      |> order_by([a], asc: fragment("DATE(?)", a.inserted_at))
      |> Repo.all()

    {:ok, rows}
  end

  # --- Private helpers ---

  defp validate_date_range(date_from, date_to) do
    if Date.compare(date_from, date_to) != :gt do
      :ok
    else
      {:error, :invalid_date_range}
    end
  end
end
```
