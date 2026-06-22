```elixir
defmodule MyApp.Platform.TenantMigrator do
  @moduledoc """
  Runs pending Ecto migrations for every active tenant schema in parallel
  without locking the entire database. Each tenant schema is migrated
  in a bounded `Task.async_stream` batch; failures are collected and
  reported rather than halting the entire run, so a single bad tenant
  does not block others.

  Intended to be invoked from a Mix release task after application
  migrations have been applied.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Platform.Tenant

  import Ecto.Query, warn: false

  @migration_path Application.compile_env(:my_app, :tenant_migration_path, "priv/tenant_migrations")
  @concurrency 5

  @type migration_result :: %{
          tenant_id: String.t(),
          schema: String.t(),
          outcome: :ok | :error,
          detail: term()
        }

  @doc """
  Migrates all active tenant schemas. Returns a summary map with
  `:succeeded` and `:failed` counts and a list of failed tenant IDs.
  """
  @spec run_all() :: %{succeeded: non_neg_integer(), failed: non_neg_integer(), errors: [map()]}
  def run_all do
    tenants = fetch_active_tenants()
    total = length(tenants)
    Logger.info("tenant_migrations_starting", tenant_count: total)

    results =
      tenants
      |> Task.async_stream(&migrate_tenant/1,
        max_concurrency: @concurrency,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{tenant_id: "unknown", schema: "unknown", outcome: :error, detail: reason}
      end)

    succeeded = Enum.count(results, &(&1.outcome == :ok))
    failed = length(results) - succeeded
    errors = Enum.filter(results, &(&1.outcome == :error))

    Logger.info("tenant_migrations_complete", succeeded: succeeded, failed: failed)
    %{succeeded: succeeded, failed: failed, errors: errors}
  end

  @spec migrate_tenant(Tenant.t()) :: migration_result()
  defp migrate_tenant(tenant) do
    schema = tenant_schema(tenant)
    Logger.info("tenant_migration_running", tenant_id: tenant.id, schema: schema)

    try do
      Ecto.Migrator.run(Repo, @migration_path, :up,
        all: true,
        prefix: schema,
        log: :info
      )

      Logger.info("tenant_migration_succeeded", tenant_id: tenant.id)
      %{tenant_id: tenant.id, schema: schema, outcome: :ok, detail: nil}
    rescue
      e ->
        reason = Exception.message(e)

        Logger.error("tenant_migration_failed",
          tenant_id: tenant.id,
          schema: schema,
          reason: reason
        )

        %{tenant_id: tenant.id, schema: schema, outcome: :error, detail: reason}
    end
  end

  @spec fetch_active_tenants() :: [Tenant.t()]
  defp fetch_active_tenants do
    Tenant
    |> where([t], t.active == true and t.bootstrapped == true)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @spec tenant_schema(Tenant.t()) :: String.t()
  defp tenant_schema(tenant), do: "tenant_#{String.replace(tenant.id, "-", "_")}"
end
```
