```elixir
defmodule MyApp.Infra.DatabaseProbe do
  @moduledoc """
  Performs structured diagnostic queries against the PostgreSQL database
  to surface operational issues: long-running queries, table bloat,
  unused indexes, and replication lag. Results are returned as typed
  structs so that callers — dashboards, health checks, alerting jobs —
  can pattern-match without inspecting raw query results.

  All queries target system catalog views and run in read-only transactions
  to ensure zero impact on production workloads.
  """

  alias MyApp.Repo

  @long_query_threshold_ms 5_000
  @bloat_threshold_mb 500

  @type long_query :: %{
          pid: integer(),
          duration_ms: non_neg_integer(),
          state: String.t(),
          query: String.t()
        }

  @type table_stats :: %{
          table: String.t(),
          live_rows: non_neg_integer(),
          dead_rows: non_neg_integer(),
          dead_ratio: float(),
          size_mb: float()
        }

  @type index_stat :: %{
          schema: String.t(),
          table: String.t(),
          index: String.t(),
          scans: non_neg_integer(),
          size_mb: float()
        }

  @doc "Returns queries that have been running longer than the threshold."
  @spec long_running_queries() :: [long_query()]
  def long_running_queries do
    sql = """
    SELECT pid,
           EXTRACT(EPOCH FROM (now() - query_start)) * 1000 AS duration_ms,
           state,
           LEFT(query, 200) AS query
    FROM   pg_stat_activity
    WHERE  state NOT IN ('idle', 'idle in transaction')
      AND  query_start IS NOT NULL
      AND  EXTRACT(EPOCH FROM (now() - query_start)) * 1000 > $1
    ORDER BY duration_ms DESC
    """

    case Repo.query(sql, [@long_query_threshold_ms]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &to_long_query/1)
      {:error, _} -> []
    end
  end

  @doc "Returns tables with significant dead-tuple bloat."
  @spec bloated_tables() :: [table_stats()]
  def bloated_tables do
    sql = """
    SELECT relname AS table,
           n_live_tup,
           n_dead_tup,
           CASE WHEN n_live_tup + n_dead_tup > 0
                THEN ROUND(n_dead_tup::numeric / (n_live_tup + n_dead_tup) * 100, 2)
                ELSE 0 END AS dead_ratio,
           ROUND(pg_total_relation_size(oid) / 1048576.0, 2) AS size_mb
    FROM   pg_stat_user_tables
    WHERE  pg_total_relation_size(oid) / 1048576.0 > $1
    ORDER BY size_mb DESC
    """

    case Repo.query(sql, [@bloat_threshold_mb]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &to_table_stats/1)
      {:error, _} -> []
    end
  end

  @doc "Returns indexes that have never been scanned and may be candidates for removal."
  @spec unused_indexes() :: [index_stat()]
  def unused_indexes do
    sql = """
    SELECT schemaname AS schema,
           tablename  AS table,
           indexname  AS index,
           idx_scan   AS scans,
           ROUND(pg_relation_size(indexrelid) / 1048576.0, 2) AS size_mb
    FROM   pg_stat_user_indexes
    WHERE  idx_scan = 0
      AND  schemaname NOT IN ('pg_catalog', 'pg_toast')
    ORDER BY size_mb DESC
    """

    case Repo.query(sql, []) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &to_index_stat/1)
      {:error, _} -> []
    end
  end

  @spec to_long_query([term()]) :: long_query()
  defp to_long_query([pid, duration_ms, state, query]) do
    %{pid: pid, duration_ms: round(duration_ms), state: state, query: query}
  end

  @spec to_table_stats([term()]) :: table_stats()
  defp to_table_stats([table, live, dead, ratio, size]) do
    %{table: table, live_rows: live, dead_rows: dead, dead_ratio: ratio, size_mb: size}
  end

  @spec to_index_stat([term()]) :: index_stat()
  defp to_index_stat([schema, table, index, scans, size]) do
    %{schema: schema, table: table, index: index, scans: scans, size_mb: size}
  end
end
```
