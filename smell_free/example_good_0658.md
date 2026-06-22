```elixir
defmodule MyApp.Platform.TenantBootstrapper do
  @moduledoc """
  Bootstraps a freshly provisioned tenant's database schema using
  per-tenant Ecto repos backed by separate PostgreSQL schemas within
  the same database instance. Each tenant schema is created, migrated,
  and seeded atomically so that any failure leaves no partial state.

  This approach (schema-per-tenant) is preferable to separate databases
  when the tenant count is large and individual database connections are
  the scarce resource.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Platform.Tenant

  @migration_path Application.compile_env(:my_app, :tenant_migration_path, "priv/tenant_migrations")
  @seed_modules [
    MyApp.Tenants.Seeds.DefaultRoles,
    MyApp.Tenants.Seeds.DefaultSettings,
    MyApp.Tenants.Seeds.DefaultEmailTemplates
  ]

  @type schema_name :: String.t()

  @doc """
  Bootstraps the schema for `tenant`. Creates the PostgreSQL schema,
  runs all tenant-scoped migrations, and seeds initial reference data.
  Returns `{:ok, tenant}` or `{:error, step, reason}`.
  """
  @spec bootstrap(Tenant.t()) ::
          {:ok, Tenant.t()} | {:error, atom(), term()}
  def bootstrap(%Tenant{} = tenant) do
    schema = schema_name(tenant)

    with :ok <- create_schema(schema),
         :ok <- run_migrations(schema),
         :ok <- seed_data(tenant, schema),
         {:ok, updated} <- mark_bootstrapped(tenant) do
      Logger.info("tenant_bootstrapped", tenant_id: tenant.id, schema: schema)
      {:ok, updated}
    else
      {:error, step, reason} ->
        Logger.error("tenant_bootstrap_failed",
          tenant_id: tenant.id,
          step: step,
          reason: inspect(reason)
        )

        drop_schema_on_failure(schema)
        {:error, step, reason}
    end
  end

  @spec create_schema(schema_name()) :: :ok | {:error, :create_schema, term()}
  defp create_schema(schema) do
    case Repo.query("CREATE SCHEMA IF NOT EXISTS #{quote_ident(schema)}") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, :create_schema, reason}
    end
  end

  @spec run_migrations(schema_name()) :: :ok | {:error, :migrations, term()}
  defp run_migrations(schema) do
    opts = [
      all: true,
      prefix: schema,
      migrations_path: @migration_path
    ]

    try do
      Ecto.Migrator.run(Repo, opts)
      :ok
    rescue
      e -> {:error, :migrations, Exception.message(e)}
    end
  end

  @spec seed_data(Tenant.t(), schema_name()) :: :ok | {:error, :seeding, term()}
  defp seed_data(tenant, schema) do
    Enum.reduce_while(@seed_modules, :ok, fn mod, :ok ->
      case mod.run(tenant, schema) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, :seeding, reason}}
      end
    end)
  end

  @spec mark_bootstrapped(Tenant.t()) :: {:ok, Tenant.t()} | {:error, :mark_bootstrapped, term()}
  defp mark_bootstrapped(tenant) do
    case tenant |> Tenant.bootstrap_changeset() |> Repo.update() do
      {:ok, t} -> {:ok, t}
      {:error, cs} -> {:error, :mark_bootstrapped, cs}
    end
  end

  @spec drop_schema_on_failure(schema_name()) :: :ok
  defp drop_schema_on_failure(schema) do
    Repo.query("DROP SCHEMA IF EXISTS #{quote_ident(schema)} CASCADE")
    :ok
  end

  @spec schema_name(Tenant.t()) :: schema_name()
  defp schema_name(tenant), do: "tenant_#{String.replace(tenant.id, "-", "_")}"

  @spec quote_ident(String.t()) :: String.t()
  defp quote_ident(name), do: "\"#{String.replace(name, "\"", "\"\"")}\"" 
end
```
