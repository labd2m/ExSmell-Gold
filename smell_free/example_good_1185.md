```elixir
defmodule Tenancy.SchemaRouter do
  @moduledoc """
  Routes Ecto repository operations to the correct PostgreSQL schema
  for a given tenant. Each tenant is isolated in a dedicated schema
  identified by a slug. Provides helpers for running cross-tenant queries.
  """

  alias Tenancy.{Repo, Tenant, TenantRegistry}

  @type tenant_slug :: String.t()

  @spec with_tenant(tenant_slug(), (-> result)) :: result | {:error, :tenant_not_found}
        when result: term()
  def with_tenant(slug, fun) when is_binary(slug) and is_function(fun, 0) do
    case TenantRegistry.fetch(slug) do
      {:ok, tenant} ->
        Repo.put_dynamic_repo(tenant.repo_name)
        result = fun.()
        Repo.put_dynamic_repo(Repo)
        result

      {:error, :not_found} ->
        {:error, :tenant_not_found}
    end
  end

  @spec provision(map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t() | atom()}
  def provision(params) when is_map(params) do
    with {:ok, tenant} <- insert_tenant(params),
         :ok <- create_schema(tenant.slug),
         :ok <- run_migrations(tenant.slug) do
      TenantRegistry.register(tenant)
      {:ok, tenant}
    end
  end

  @spec deprovision(tenant_slug()) :: :ok | {:error, atom()}
  def deprovision(slug) when is_binary(slug) do
    with {:ok, tenant} <- TenantRegistry.fetch(slug),
         :ok <- drop_schema(slug) do
      TenantRegistry.deregister(tenant)
      Repo.delete(tenant)
      :ok
    end
  end

  @spec list_tenant_slugs() :: [tenant_slug()]
  def list_tenant_slugs do
    import Ecto.Query
    from(t in Tenant, select: t.slug, where: t.active == true) |> Repo.all()
  end

  @spec each_tenant((tenant_slug() -> :ok)) :: :ok
  def each_tenant(fun) when is_function(fun, 1) do
    list_tenant_slugs()
    |> Enum.each(fn slug ->
      with_tenant(slug, fn -> fun.(slug) end)
    end)
  end

  @spec insert_tenant(map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  defp insert_tenant(params) do
    %Tenant{} |> Tenant.creation_changeset(params) |> Repo.insert()
  end

  @spec create_schema(tenant_slug()) :: :ok | {:error, atom()}
  defp create_schema(slug) do
    schema = sanitize_slug(slug)

    case Repo.query("CREATE SCHEMA IF NOT EXISTS \"#{schema}\"") do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :schema_creation_failed}
    end
  end

  @spec drop_schema(tenant_slug()) :: :ok | {:error, atom()}
  defp drop_schema(slug) do
    schema = sanitize_slug(slug)

    case Repo.query("DROP SCHEMA IF EXISTS \"#{schema}\" CASCADE") do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :schema_drop_failed}
    end
  end

  @spec run_migrations(tenant_slug()) :: :ok
  defp run_migrations(slug) do
    Ecto.Migrator.run(Repo, :up, prefix: slug, all: true)
    :ok
  end

  @spec sanitize_slug(tenant_slug()) :: String.t()
  defp sanitize_slug(slug) do
    slug
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
  end
end
```
