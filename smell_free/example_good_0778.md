```elixir
defmodule Data.SchemaMigrationDiffer do
  @moduledoc """
  Computes the structural diff between two schema snapshots represented as
  plain maps. Used by migration tooling to determine which columns were
  added, dropped, or altered between schema versions. All logic is pure;
  no database connection is required.
  """

  @type column_def :: %{type: atom(), nullable: boolean(), default: term()}
  @type table_schema :: %{String.t() => column_def()}
  @type schema_snapshot :: %{String.t() => table_schema()}

  @type column_change ::
          {:added, String.t(), column_def()}
          | {:dropped, String.t(), column_def()}
          | {:altered, String.t(), column_def(), column_def()}

  @type table_change ::
          {:table_added, String.t(), table_schema()}
          | {:table_dropped, String.t(), table_schema()}
          | {:table_altered, String.t(), [column_change()]}

  @type diff_result :: [table_change()]

  @doc """
  Returns the ordered list of changes needed to move from `old_schema`
  to `new_schema`. Table additions come first, alterations second,
  and drops last to minimise dependency conflicts.
  """
  @spec diff(schema_snapshot(), schema_snapshot()) :: diff_result()
  def diff(old_schema, new_schema)
      when is_map(old_schema) and is_map(new_schema) do
    old_tables = MapSet.new(Map.keys(old_schema))
    new_tables = MapSet.new(Map.keys(new_schema))

    added_tables =
      MapSet.difference(new_tables, old_tables)
      |> Enum.map(fn table -> {:table_added, table, Map.fetch!(new_schema, table)} end)

    dropped_tables =
      MapSet.difference(old_tables, new_tables)
      |> Enum.map(fn table -> {:table_dropped, table, Map.fetch!(old_schema, table)} end)

    altered_tables =
      MapSet.intersection(old_tables, new_tables)
      |> Enum.flat_map(fn table ->
        changes = diff_table(Map.fetch!(old_schema, table), Map.fetch!(new_schema, table))
        if Enum.empty?(changes), do: [], else: [{:table_altered, table, changes}]
      end)

    added_tables ++ altered_tables ++ dropped_tables
  end

  @doc "Returns true when the two snapshots are structurally identical."
  @spec identical?(schema_snapshot(), schema_snapshot()) :: boolean()
  def identical?(old_schema, new_schema) do
    diff(old_schema, new_schema) == []
  end

  @doc "Returns all table names that have any change between the two snapshots."
  @spec changed_tables(schema_snapshot(), schema_snapshot()) :: [String.t()]
  def changed_tables(old_schema, new_schema) do
    diff(old_schema, new_schema)
    |> Enum.map(fn
      {:table_added, name, _} -> name
      {:table_dropped, name, _} -> name
      {:table_altered, name, _} -> name
    end)
  end

  defp diff_table(old_cols, new_cols) do
    old_keys = MapSet.new(Map.keys(old_cols))
    new_keys = MapSet.new(Map.keys(new_cols))

    added = MapSet.difference(new_keys, old_keys) |> Enum.map(fn col ->
      {:added, col, Map.fetch!(new_cols, col)}
    end)

    dropped = MapSet.difference(old_keys, new_keys) |> Enum.map(fn col ->
      {:dropped, col, Map.fetch!(old_cols, col)}
    end)

    altered = MapSet.intersection(old_keys, new_keys) |> Enum.flat_map(fn col ->
      old_def = Map.fetch!(old_cols, col)
      new_def = Map.fetch!(new_cols, col)
      if old_def == new_def, do: [], else: [{:altered, col, old_def, new_def}]
    end)

    added ++ altered ++ dropped
  end
end
```
