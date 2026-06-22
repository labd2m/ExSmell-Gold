```elixir
defmodule MyApp.DataPipeline.SchemaMigrator do
  @moduledoc """
  Transforms records between schema versions when reading data written
  by an older version of the application. Each migration is a versioned
  module implementing the `SchemaMigration` behaviour; migrations are
  applied in sequence until the record reaches the current schema version.

  This approach allows older records to co-exist in the database with
  newer ones without a bulk migration job, trading a small amount of
  per-read overhead for operational simplicity.
  """

  @current_version 3

  @migrations %{
    1 => MyApp.DataPipeline.Migrations.V1ToV2,
    2 => MyApp.DataPipeline.Migrations.V2ToV3
  }

  @type versioned_record :: %{required(:schema_version) => pos_integer(), optional(atom()) => term()}

  @doc """
  Migrates `record` from its current schema version to
  `#{@current_version}`. Returns the record unchanged if it is already
  at the current version.
  """
  @spec migrate(versioned_record()) :: {:ok, versioned_record()} | {:error, term()}
  def migrate(%{schema_version: version} = record) when version == @current_version do
    {:ok, record}
  end

  def migrate(%{schema_version: version} = record) when version < @current_version do
    apply_migrations(record, version)
  end

  def migrate(%{schema_version: version}) when version > @current_version do
    {:error, {:future_schema_version, version}}
  end

  def migrate(_), do: {:error, :missing_schema_version}

  @doc "Returns the current schema version this migrator targets."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "Returns `true` when `record` is already at the current version."
  @spec current?(%{schema_version: pos_integer()}) :: boolean()
  def current?(%{schema_version: v}), do: v == @current_version

  @spec apply_migrations(versioned_record(), pos_integer()) ::
          {:ok, versioned_record()} | {:error, term()}
  defp apply_migrations(record, from_version) do
    from_version
    |> Range.new(@current_version - 1)
    |> Enum.reduce_while({:ok, record}, fn version, {:ok, current} ->
      case Map.get(@migrations, version) do
        nil ->
          {:halt, {:error, {:no_migration_for_version, version}}}

        module ->
          case module.up(current) do
            {:ok, migrated} ->
              {:cont, {:ok, %{migrated | schema_version: version + 1}}}

            {:error, reason} ->
              {:halt, {:error, {:migration_failed, version, reason}}}
          end
      end
    end)
  end
end

defmodule MyApp.DataPipeline.SchemaMigration do
  @moduledoc "Behaviour contract for record schema migration modules."

  @callback up(MyApp.DataPipeline.SchemaMigrator.versioned_record()) ::
              {:ok, MyApp.DataPipeline.SchemaMigrator.versioned_record()} | {:error, term()}
end
```
