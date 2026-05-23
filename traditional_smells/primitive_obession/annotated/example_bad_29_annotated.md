# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `Reporting.FinancialSummary` module — date range parameters in all functions |
| **Affected functions** | `generate_revenue_report/2`, `compute_period_growth/3`, `export_to_csv/2`, `fetch_transactions_in_range/2` |
| **Short explanation** | Date ranges are passed as a pair of plain `String.t()` values in ISO-8601 format (`"2024-01-01"`, `"2024-03-31"`) rather than a dedicated `%DateRange{start: Date.t(), end: Date.t(), label: String.t()}` struct. This forces each function to independently parse the string into a `Date`, adds error handling boilerplate for invalid formats, and hides the semantic relationship between the two date bounds. |

```elixir
defmodule Reporting.FinancialSummary do
  @moduledoc """
  Generates revenue, expense, and growth reports for the finance team.
  Supports arbitrary date ranges and CSV export for the back-office
  dashboard.
  """

  require Logger

  alias Reporting.Repo
  alias Reporting.Schema.Transaction
  alias Reporting.CSVExporter

  @supported_groupings [:day, :week, :month]

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because date ranges are passed as two
  # plain ISO-8601 strings ("2024-01-01", "2024-03-31") instead of a
  # dedicated %DateRange{start: ~D[...], end: ~D[...]} struct.
  # Every function must independently parse the strings with Date.from_iso8601!/1,
  # and validation logic is duplicated. A struct would centralize parsing and
  # make the range an explicit domain concept.

  @spec generate_revenue_report(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def generate_revenue_report(start_date_str, end_date_str)
      when is_binary(start_date_str) and is_binary(end_date_str) do
    with {:ok, start_date} <- parse_date(start_date_str),
         {:ok, end_date} <- parse_date(end_date_str),
         :ok <- validate_range(start_date, end_date),
         transactions <- fetch_transactions_in_range(start_date_str, end_date_str) do
      grouped = group_by_month(transactions)

      summary = %{
        period_start: start_date_str,
        period_end: end_date_str,
        total_revenue: Enum.sum(Enum.map(transactions, & &1.amount)),
        transaction_count: length(transactions),
        monthly_breakdown: grouped,
        generated_at: DateTime.utc_now()
      }

      Logger.info("Revenue report generated for #{start_date_str} – #{end_date_str}")
      {:ok, summary}
    end
  end

  @spec compute_period_growth(String.t(), String.t(), String.t()) ::
          {:ok, float()} | {:error, term()}
  def compute_period_growth(current_start_str, current_end_str, comparison_start_str)
      when is_binary(current_start_str) and is_binary(current_end_str) do
    with {:ok, current_start} <- parse_date(current_start_str),
         {:ok, current_end} <- parse_date(current_end_str),
         {:ok, comparison_start} <- parse_date(comparison_start_str),
         :ok <- validate_range(current_start, current_end) do
      period_length = Date.diff(current_end, current_start)
      comparison_end = Date.add(comparison_start, period_length)
      comparison_end_str = Date.to_iso8601(comparison_end)

      current_txns = fetch_transactions_in_range(current_start_str, current_end_str)
      prior_txns = fetch_transactions_in_range(comparison_start_str, comparison_end_str)

      current_total = Enum.sum(Enum.map(current_txns, & &1.amount))
      prior_total = Enum.sum(Enum.map(prior_txns, & &1.amount))

      growth =
        if prior_total == 0.0 do
          0.0
        else
          Float.round((current_total - prior_total) / prior_total * 100.0, 2)
        end

      {:ok, growth}
    end
  end

  @spec export_to_csv(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def export_to_csv(start_date_str, end_date_str)
      when is_binary(start_date_str) and is_binary(end_date_str) do
    with {:ok, start_date} <- parse_date(start_date_str),
         {:ok, end_date} <- parse_date(end_date_str),
         :ok <- validate_range(start_date, end_date),
         transactions <- fetch_transactions_in_range(start_date_str, end_date_str) do
      rows =
        Enum.map(transactions, fn txn ->
          [txn.id, txn.customer_id, txn.amount, txn.currency, txn.inserted_at]
        end)

      headers = ["id", "customer_id", "amount", "currency", "created_at"]
      CSVExporter.encode([headers | rows])
    end
  end

  @spec fetch_transactions_in_range(String.t(), String.t()) :: list(Transaction.t())
  def fetch_transactions_in_range(start_date_str, end_date_str)
      when is_binary(start_date_str) and is_binary(end_date_str) do
    {:ok, start_date} = parse_date(start_date_str)
    {:ok, end_date} = parse_date(end_date_str)

    Repo.all(
      from t in Transaction,
        where: fragment("?::date", t.inserted_at) >= ^start_date and
               fragment("?::date", t.inserted_at) <= ^end_date,
        order_by: [asc: t.inserted_at]
    )
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, {:invalid_date_format, date_str}}
    end
  end

  defp validate_range(start_date, end_date) do
    cond do
      Date.compare(end_date, start_date) == :lt ->
        {:error, {:end_before_start, start_date, end_date}}

      Date.diff(end_date, start_date) > 366 ->
        {:error, :range_exceeds_one_year}

      true ->
        :ok
    end
  end

  defp group_by_month(transactions) do
    transactions
    |> Enum.group_by(fn txn ->
      date = DateTime.to_date(txn.inserted_at)
      "#{date.year}-#{String.pad_leading(Integer.to_string(date.month), 2, "0")}"
    end)
    |> Enum.map(fn {month, txns} ->
      %{month: month, total: Enum.sum(Enum.map(txns, & &1.amount)), count: length(txns)}
    end)
    |> Enum.sort_by(& &1.month)
  end
end
```
