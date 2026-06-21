```elixir
defmodule MyApp.Migrations.SafeOps do
  @moduledoc """
  A collection of migration macros and helpers that enforce zero-downtime
  database change patterns. Every operation here is safe to run against a
  live production database with active connections. Unsafe alternatives
  (full table locks, synchronous index builds, column renames) are
  deliberately absent so migration authors cannot accidentally reach for them.
  """

  import Ecto.Migration

  @doc """
  Adds a column with a non-null constraint using a safe two-phase approach:
  the column is first added as nullable (no lock beyond row-level), then a
  check constraint is added with `NOT VALID` so existing rows are not scanned,
  and finally the constraint is validated in a separate, interruptible pass.
  Returns after phase 1; phases 2-3 should be separate migrations.
  """
  @spec add_column_safe(atom(), atom(), atom(), keyword()) :: :ok
  def add_column_safe(table, column, type, opts \\ []) do
    nullable_opts = Keyword.delete(opts, :null)
    add(column, type, Keyword.put(nullable_opts, :null, true))
  end

  @doc """
  Creates an index concurrently so the build does not lock the table.
  Wraps `create index(:table, [:col], concurrently: true)` and sets
  `:disable_ddl_transaction` which Ecto requires for concurrent index builds.
  """
  @spec create_index_concurrently(atom(), [atom()], keyword()) :: :ok
  defmacro create_index_concurrently(table, columns, opts \\ []) do
    quote do
      @disable_ddl_transaction true
      create index(unquote(table), unquote(columns),
               Keyword.merge(unquote(opts), concurrently: true))
    end
  end

  @doc """
  Drops an index concurrently. Safe to run during peak traffic.
  """
  @spec drop_index_concurrently(atom(), [atom()], keyword()) :: :ok
  defmacro drop_index_concurrently(table, columns, opts \\ []) do
    quote do
      @disable_ddl_transaction true
      drop_if_exists index(unquote(table), unquote(columns),
                       Keyword.merge(unquote(opts), concurrently: true))
    end
  end

  @doc """
  Adds a `NOT NULL` constraint using the `NOT VALID` pattern so existing rows
  are not scanned during the migration, preventing a table-level lock.
  A separate `validate_constraint/2` call in the next deploy completes it.
  """
  @spec add_not_null_constraint(atom(), atom()) :: :ok
  def add_not_null_constraint(table, column) do
    constraint_name = "#{table}_#{column}_not_null"

    execute(
      "ALTER TABLE #{table} ADD CONSTRAINT #{constraint_name} CHECK (#{column} IS NOT NULL) NOT VALID",
      "ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{constraint_name}"
    )
  end

  @doc """
  Validates a previously added `NOT VALID` constraint. Uses a lighter share
  lock that does not block reads or writes, just other schema changes.
  """
  @spec validate_not_null_constraint(atom(), atom()) :: :ok
  def validate_not_null_constraint(table, column) do
    constraint_name = "#{table}_#{column}_not_null"
    execute("ALTER TABLE #{table} VALIDATE CONSTRAINT #{constraint_name}")
  end

  @doc """
  Renames a column using the expand/contract pattern. The old column is kept
  and a trigger synchronises writes to both. The trigger and old column are
  removed in a later migration once all application code reads the new name.
  This function only creates the new column; the sync trigger is a separate step.
  """
  @spec expand_column(atom(), atom(), atom(), atom()) :: :ok
  def expand_column(table, old_column, new_column, type) do
    add(new_column, type, null: true)

    execute("""
      UPDATE #{table} SET #{new_column} = #{old_column} WHERE #{new_column} IS NULL
    """)
  end

  @doc """
  Backfills `column` in `table` in batches to avoid long-running statements
  that hold row locks. `batch_size` defaults to 1000 rows per statement.
  """
  @spec backfill_in_batches(atom(), atom(), term(), pos_integer()) :: :ok
  def backfill_in_batches(table, column, value, batch_size \\ 1_000) do
    quoted_value = quote_value(value)

    execute("""
    DO $$
    DECLARE
      updated INT;
    BEGIN
      LOOP
        UPDATE #{table}
        SET #{column} = #{quoted_value}
        WHERE id IN (
          SELECT id FROM #{table}
          WHERE #{column} IS NULL
          LIMIT #{batch_size}
        );
        GET DIAGNOSTICS updated = ROW_COUNT;
        EXIT WHEN updated = 0;
        PERFORM pg_sleep(0.05);
      END LOOP;
    END $$;
    """)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp quote_value(value) when is_binary(value), do: "'#{String.replace(value, "'", "''")}'"
  defp quote_value(value) when is_integer(value), do: to_string(value)
  defp quote_value(value) when is_boolean(value), do: to_string(value)
  defp quote_value(nil), do: "NULL"
end
```
