```elixir
defmodule Mix.Tasks.Db.Analyze.Indexes do
  @moduledoc """
  Analyzes index usage in the PostgreSQL database and reports potentially
  missing or unused indexes based on query statistics and foreign key columns.

  This task is read-only and makes no changes to the database schema.

  ## Usage

      mix db.analyze.indexes
      mix db.analyze.indexes --min-scans 100
      mix db.analyze.indexes --unused-threshold 10

  """

  use Mix.Task

  @shortdoc "Reports missing and unused database indexes"

  @default_min_scans 50
  @default_unused_threshold 5

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [min_scans: :integer, unused_threshold: :integer]
      )

    min_scans = Keyword.get(opts, :min_scans, @default_min_scans)
    unused_threshold = Keyword.get(opts, :unused_threshold, @default_unused_threshold)

    Mix.Task.run("app.start")
    Mix.shell().info("\n=== Database Index Analysis ===\n")

    report_missing_fk_indexes()
    report_unused_indexes(unused_threshold)
    report_high_seq_scan_tables(min_scans)
    report_index_bloat()
  end

  defp report_missing_fk_indexes do
    Mix.shell().info("--- Foreign Keys Without Indexes ---")

    query = """
    SELECT
      tc.table_name,
      kcu.column_name,
      ccu.table_name AS foreign_table
    FROM information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
    JOIN information_schema.referential_constraints AS rc
      ON tc.constraint_name = rc.constraint_name
    JOIN information_schema.constraint_column_usage AS ccu
      ON rc.unique_constraint_name = ccu.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = tc.table_name
          AND indexdef ILIKE '%' || kcu.column_name || '%'
      )
    ORDER BY tc.table_name, kcu.column_name;
    """

    results = Platform.Repo.query!(query).rows

    if results == [] do
      Mix.shell().info("  ✓ All foreign keys are indexed\n")
    else
      Enum.each(results, fn [table, column, foreign_table] ->
        Mix.shell().info("  ⚠ #{table}.#{column} → #{foreign_table} (missing index)")
      end)
      Mix.shell().info("")
    end
  end

  defp report_unused_indexes(threshold) do
    Mix.shell().info("--- Indexes With Low Usage (< #{threshold} scans) ---")

    query = """
    SELECT
      schemaname || '.' || tablename AS table,
      indexname,
      idx_scan AS scans
    FROM pg_stat_user_indexes
    WHERE idx_scan < $1
      AND indexname NOT LIKE '%_pkey'
    ORDER BY idx_scan ASC, tablename;
    """

    results = Platform.Repo.query!(query, [threshold]).rows

    if results == [] do
      Mix.shell().info("  ✓ No low-usage indexes found\n")
    else
      Enum.each(results, fn [table, index, scans] ->
        Mix.shell().info("  ⚠ #{table}: #{index} (#{scans} scans)")
      end)
      Mix.shell().info("")
    end
  end

  defp report_high_seq_scan_tables(min_scans) do
    Mix.shell().info("--- Tables With High Sequential Scans ---")

    query = """
    SELECT
      relname AS table,
      seq_scan,
      idx_scan,
      n_live_tup AS rows
    FROM pg_stat_user_tables
    WHERE seq_scan > $1
      AND seq_scan > idx_scan
    ORDER BY seq_scan DESC
    LIMIT 10;
    """

    results = Platform.Repo.query!(query, [min_scans]).rows

    if results == [] do
      Mix.shell().info("  ✓ No tables with excessive sequential scans\n")
    else
      Enum.each(results, fn [table, seq, idx, rows] ->
        Mix.shell().info("  ⚠ #{table}: #{seq} seq scans vs #{idx} idx scans (#{rows} rows)")
      end)
      Mix.shell().info("")
    end
  end

  defp report_index_bloat do
    Mix.shell().info("--- Summary ---")
    Mix.shell().info("  Run ANALYZE to update statistics if results seem stale.")
    Mix.shell().info("  Run REINDEX on bloated indexes to reclaim space.\n")
  end
end
```
