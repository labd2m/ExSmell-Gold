# Annotated Bad Example 11

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@read_replica_dsn` defined at the top of `Reporting.QueryExecutor`
- **Affected function(s):** `run_sales_report/2`, `run_churn_report/1`, `run_cohort_analysis/2`
- **Short explanation:** `Application.fetch_env!/2` is used in the module body to assign the database DSN to a module attribute. Module attributes are evaluated during compilation; if the `:reporting` application environment has not been loaded yet, this can generate a compilation warning or raise an `ArgumentError`.

---

```elixir
defmodule Reporting.QueryExecutor do
  @moduledoc """
  Executes heavy read-only analytical queries against the reporting
  read-replica. Each public function corresponds to a named report type
  consumed by the business-intelligence dashboard.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is evaluated in the
  # VALIDATION: module body to populate a module attribute. Module attributes are
  # VALIDATION: assigned at compile-time, but the :reporting OTP application configuration
  # VALIDATION: may not be in memory yet, causing a warning or ArgumentError during
  # VALIDATION: compilation.
  @read_replica_dsn Application.fetch_env!(:reporting, :read_replica_dsn)
  # VALIDATION: SMELL END

  @query_timeout_ms 60_000
  @max_rows 50_000

  @type date_range :: %{from: Date.t(), to: Date.t()}
  @type report_row :: map()
  @type report_result :: {:ok, [report_row()]} | {:error, term()}

  @doc """
  Returns daily sales totals grouped by product category for the given date range.

  ## Parameters
    - `range` - A `%{from: Date.t(), to: Date.t()}` map.
    - `opts` - Optional keyword list; `:currency` defaults to `"USD"`.
  """
  @spec run_sales_report(date_range(), keyword()) :: report_result()
  def run_sales_report(%{from: from_date, to: to_date} = _range, opts \\ []) do
    currency = Keyword.get(opts, :currency, "USD")

    Logger.info("Running sales report from=#{from_date} to=#{to_date} currency=#{currency}")

    sql = """
    SELECT
      order_date::date               AS day,
      product_category,
      SUM(amount_cents) / 100.0      AS total,
      COUNT(*)                       AS order_count
    FROM orders
    WHERE order_date BETWEEN $1 AND $2
      AND currency = $3
      AND status = 'completed'
    GROUP BY 1, 2
    ORDER BY 1, 2
    LIMIT #{@max_rows}
    """

    execute_query(sql, [from_date, to_date, currency])
  end

  @doc """
  Returns monthly churn counts alongside the subscription cancellation reasons.

  ## Parameters
    - `range` - A `%{from: Date.t(), to: Date.t()}` map.
  """
  @spec run_churn_report(date_range()) :: report_result()
  def run_churn_report(%{from: from_date, to: to_date}) do
    Logger.info("Running churn report from=#{from_date} to=#{to_date}")

    sql = """
    SELECT
      DATE_TRUNC('month', cancelled_at) AS month,
      cancellation_reason,
      COUNT(*)                          AS churn_count
    FROM subscriptions
    WHERE cancelled_at BETWEEN $1 AND $2
    GROUP BY 1, 2
    ORDER BY 1, 2
    """

    execute_query(sql, [from_date, to_date])
  end

  @doc """
  Performs a user cohort analysis: groups users by signup month and tracks
  their retention over subsequent months.

  ## Parameters
    - `range` - The signup date range to include in the analysis.
    - `retention_months` - How many months forward to track; defaults to `6`.
  """
  @spec run_cohort_analysis(date_range(), pos_integer()) :: report_result()
  def run_cohort_analysis(%{from: from_date, to: to_date}, retention_months \\ 6) do
    Logger.info("Running cohort analysis from=#{from_date} to=#{to_date} months=#{retention_months}")

    sql = """
    WITH cohorts AS (
      SELECT
        user_id,
        DATE_TRUNC('month', created_at) AS cohort_month
      FROM users
      WHERE created_at BETWEEN $1 AND $2
    ),
    activity AS (
      SELECT DISTINCT
        c.cohort_month,
        c.user_id,
        DATE_TRUNC('month', e.occurred_at) AS activity_month
      FROM cohorts c
      JOIN events e ON e.user_id = c.user_id
      WHERE e.occurred_at <= $2 + INTERVAL '#{retention_months} months'
    )
    SELECT
      cohort_month,
      EXTRACT(MONTH FROM AGE(activity_month, cohort_month)) AS months_since_signup,
      COUNT(DISTINCT user_id)                               AS retained_users
    FROM activity
    GROUP BY 1, 2
    ORDER BY 1, 2
    """

    execute_query(sql, [from_date, to_date])
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp execute_query(sql, params) do
    conn_opts = [url: @read_replica_dsn, timeout: @query_timeout_ms]

    case Postgrex.query(conn_opts, sql, params, timeout: @query_timeout_ms) do
      {:ok, %Postgrex.Result{columns: columns, rows: rows}} ->
        string_cols = Enum.map(columns, &String.to_atom/1)
        mapped = Enum.map(rows, fn row -> Enum.zip(string_cols, row) |> Map.new() end)
        {:ok, mapped}

      {:error, %Postgrex.Error{message: msg}} ->
        Logger.error("Query failed message=#{msg}")
        {:error, msg}
    end
  end
end
```
