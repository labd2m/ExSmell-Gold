```elixir
defmodule RevenueReporter do
  @moduledoc """
  Generates revenue and financial summary reports for specified billing periods,
  supporting CSV and JSON export formats.
  """

  alias RevenueReporter.{ExportFormatter, LedgerQuery, ReportResult}
  require Logger

  @supported_formats [:json, :csv]

  @doc """
  Returns a list of all available billing periods (year-month tuples) for
  which transaction data exists.
  """
  def available_periods do
    LedgerQuery.distinct_billing_periods()
  end

  @doc """
  Exports a pre-built `%ReportResult{}` to the requested format.
  Returns `{:ok, binary}` where the binary is the serialised report content.
  """
  def export_report(%ReportResult{} = result, format) when format in @supported_formats do
    ExportFormatter.format(result, format)
  end

  # Generates a revenue summary report for a given calendar month.
  #
  # Parameters:
  #   year  - integer, 4-digit calendar year (e.g. 2024)
  #   month - integer, month number 1..12
  #
  # The report includes:
  #   - gross_revenue:   total revenue before refunds
  #   - net_revenue:     gross minus refunds and chargebacks
  #   - transaction_count: total number of successful transactions
  #   - refund_count:    number of refund events in the period
  #   - currency_breakdown: map of currency => net_revenue
  #   - top_products:   list of top 10 products by revenue, descending
  #
  # Returns {:ok, %ReportResult{}} on success.
  # Returns {:error, :no_data} when no transactions exist for the period.
  # Returns {:error, :invalid_period} for out-of-range month values.
  def generate_monthly_report(year, month)
      when is_integer(year) and is_integer(month) and month in 1..12 do
    period_start = Date.new!(year, month, 1)
    period_end = Date.end_of_month(period_start)

    case LedgerQuery.transactions_for_period(period_start, period_end) do
      [] ->
        {:error, :no_data}

      transactions ->
        gross = Enum.sum_by(transactions, & &1.amount)
        refunds = transactions |> Enum.filter(&(&1.type == :refund)) |> Enum.sum_by(& &1.amount)
        net = gross - refunds

        currency_breakdown =
          transactions
          |> Enum.group_by(& &1.currency)
          |> Map.new(fn {cur, txns} ->
            {cur, Enum.sum_by(txns, & &1.amount) - Enum.sum_by(Enum.filter(txns, &(&1.type == :refund)), & &1.amount)}
          end)

        top_products =
          transactions
          |> Enum.group_by(& &1.product_id)
          |> Enum.map(fn {pid, txns} -> {pid, Enum.sum_by(txns, & &1.amount)} end)
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(10)

        result = %ReportResult{
          period: {year, month},
          gross_revenue: gross,
          net_revenue: net,
          transaction_count: Enum.count(transactions, &(&1.type == :charge)),
          refund_count: Enum.count(transactions, &(&1.type == :refund)),
          currency_breakdown: currency_breakdown,
          top_products: top_products
        }

        {:ok, result}
    end
  end


  @doc """
  Generates a year-to-date summary by aggregating monthly reports from
  January through the given month.
  """
  def generate_ytd_report(year, through_month \\ nil) when is_integer(year) do
    up_to = through_month || DateTime.utc_now().month

    1..up_to
    |> Enum.reduce_while({:ok, []}, fn month, {:ok, acc} ->
      case generate_monthly_report(year, month) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, :no_data} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_data}
      {:ok, results} -> {:ok, ReportResult.aggregate(Enum.reverse(results))}
      error -> error
    end
  end

  @doc """
  Logs a summary line for the given report result.
  """
  def log_report_summary(%ReportResult{period: {y, m}, net_revenue: net}) do
    Logger.info("Report #{y}-#{String.pad_leading("#{m}", 2, "0")}: net revenue = #{net}")
  end
end
```
