```elixir
defmodule Platform.TenantSchema do
  @moduledoc """
  Helpers for schema-per-tenant database isolation using PostgreSQL schemas.

  Each tenant's data lives in a dedicated database schema (e.g. `tenant_42`),
  completely isolated from other tenants. This module manages schema creation,
  migration execution, and the `search_path` configuration required to route
  Ecto queries to the correct schema.
  """

  alias Platform.Repo

  @type tenant_id :: pos_integer()
  @type schema_name :: String.t()

  @shared_schema "public"
  @tenant_prefix "tenant_"

  @doc "Returns the PostgreSQL schema name for the given tenant."
  @spec schema_for(tenant_id()) :: schema_name()
  def schema_for(tenant_id) when is_integer(tenant_id) and tenant_id > 0 do
    "#{@tenant_prefix}#{tenant_id}"
  end

  @doc """
  Creates the database schema for a tenant and runs all pending migrations
  against it. Idempotent: safe to call if the schema already exists.
  """
  @spec provision(tenant_id()) :: :ok | {:error, term()}
  def provision(tenant_id) when is_integer(tenant_id) do
    schema = schema_for(tenant_id)

    with :ok <- create_schema(schema),
         :ok <- run_migrations(schema) do
      :ok
    end
  end

  @doc """
  Executes `fun` with the Repo's `search_path` set to the tenant's schema.
  All Ecto queries inside `fun` will target the tenant's tables.
  """
  @spec with_tenant(tenant_id(), (-> term())) :: term()
  def with_tenant(tenant_id, fun) when is_function(fun, 0) do
    schema = schema_for(tenant_id)
    set_search_path(schema)

    try do
      fun.()
    after
      set_search_path(@shared_schema)
    end
  end

  @doc """
  Drops the tenant schema and all its tables. Irreversible.
  Requires explicit confirmation to prevent accidental deletion.
  """
  @spec deprovision(tenant_id(), :i_understand_this_is_irreversible) ::
          :ok | {:error, term()}
  def deprovision(tenant_id, :i_understand_this_is_irreversible) when is_integer(tenant_id) do
    schema = schema_for(tenant_id)
    sql = "DROP SCHEMA #{quote_schema(schema)} CASCADE"

    case Repo.query(sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists all tenant schema names present in the database."
  @spec list_tenant_schemas() :: [schema_name()]
  def list_tenant_schemas do
    sql = """
    SELECT schema_name FROM information_schema.schemata
    WHERE schema_name LIKE $1
    ORDER BY schema_name
    """

    case Repo.query(sql, ["#{@tenant_prefix}%"]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &List.first/1)
      _ -> []
    end
  end

  @doc "Returns `true` if the tenant schema exists in the database."
  @spec exists?(tenant_id()) :: boolean()
  def exists?(tenant_id) when is_integer(tenant_id) do
    schema = schema_for(tenant_id)
    schema in list_tenant_schemas()
  end

  defp create_schema(schema) do
    sql = "CREATE SCHEMA IF NOT EXISTS #{quote_schema(schema)}"
    case Repo.query(sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:schema_creation_failed, reason}}
    end
  end

  defp run_migrations(schema) do
    set_search_path(schema)

    try do
      Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, prefix: schema)
      :ok
    rescue
      error -> {:error, {:migration_failed, error}}
    after
      set_search_path(@shared_schema)
    end
  end

  defp set_search_path(schema) do
    Repo.query!("SET search_path TO #{quote_schema(schema)}, #{@shared_schema}")
  end

  defp migrations_path do
    Application.app_dir(:platform, "priv/tenant_migrations")
  end

  defp quote_schema(schema) do
    ~s("#{String.replace(schema, ~s("), ~s(""))}")
  end
end
```
