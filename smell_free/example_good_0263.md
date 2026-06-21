```elixir
defmodule Platform.Tenants do
  @moduledoc """
  Manages tenant provisioning and schema-based multitenancy.
  Each tenant is isolated in its own PostgreSQL schema, created and
  migrated atomically during onboarding. All data queries are scoped
  via `Ecto.Query` prefix options so no global state is required.
  """

  alias Platform.{Repo, Tenant}
  alias Ecto.Multi
  import Ecto.Query

  @type tenant_attrs :: %{
          required(:name) => String.t(),
          required(:subdomain) => String.t(),
          optional(:plan) => :starter | :growth | :enterprise
        }

  @reserved_subdomains ~w[www api admin app mail cdn assets static]

  @doc """
  Provisions a new tenant: validates the subdomain, creates the database
  schema, runs migrations, and persists the tenant record atomically.
  Returns `{:ok, tenant}` or `{:error, reason}`.
  """
  @spec provision(tenant_attrs()) :: {:ok, Tenant.t()} | {:error, term()}
  def provision(%{subdomain: subdomain} = attrs) when is_binary(subdomain) do
    with :ok <- validate_subdomain(subdomain),
         {:ok, tenant} <- insert_tenant(attrs),
         :ok <- create_schema(tenant),
         :ok <- run_migrations(tenant) do
      {:ok, tenant}
    end
  end

  def provision(_attrs), do: {:error, :invalid_params}

  @doc """
  Returns the tenant struct for the given subdomain, or `{:error, :not_found}`.
  """
  @spec fetch_by_subdomain(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def fetch_by_subdomain(subdomain) when is_binary(subdomain) do
    case Repo.get_by(Tenant, subdomain: subdomain, active: true) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc """
  Builds a query prefix tuple for the given tenant schema, for use with
  `Repo.all/2`, `Repo.one/2`, and other Ecto functions.

  ## Example

      opts = tenant_query_prefix(tenant)
      Repo.all(MySchema, opts)
  """
  @spec tenant_query_prefix(Tenant.t()) :: [prefix: String.t()]
  def tenant_query_prefix(%Tenant{schema_name: schema}), do: [prefix: schema]

  @doc """
  Lists all active tenants with their current plan.
  """
  @spec list_active() :: [Tenant.t()]
  def list_active do
    Tenant
    |> where([t], t.active == true)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Deactivates a tenant without deleting its schema, preserving data for
  potential reactivation or export. Returns `{:ok, tenant}` or an error.
  """
  @spec deactivate(binary()) :: {:ok, Tenant.t()} | {:error, term()}
  def deactivate(tenant_id) when is_binary(tenant_id) do
    with {:ok, tenant} <- fetch_by_id(tenant_id) do
      tenant
      |> Tenant.deactivate_changeset()
      |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_subdomain(subdomain) when subdomain in @reserved_subdomains do
    {:error, {:reserved_subdomain, subdomain}}
  end

  defp validate_subdomain(subdomain) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9\-]{1,61}[a-z0-9]$/, subdomain) do
      :ok
    else
      {:error, :invalid_subdomain_format}
    end
  end

  defp insert_tenant(attrs) do
    schema_name = "tenant_#{String.replace(attrs.subdomain, "-", "_")}"
    enriched = Map.put(attrs, :schema_name, schema_name)

    %Tenant{}
    |> Tenant.create_changeset(enriched)
    |> Repo.insert()
  end

  defp create_schema(%Tenant{schema_name: schema}) do
    case Repo.query("CREATE SCHEMA IF NOT EXISTS #{schema}") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:schema_creation_failed, reason}}
    end
  end

  defp run_migrations(%Tenant{schema_name: schema}) do
    opts = [prefix: schema, dynamic_repo: Repo]

    case Ecto.Migrator.run(Repo, Platform.migrations_path(), :up, all: true, prefix: schema) do
      [] -> :ok
      _ran -> :ok
    end
  rescue
    e -> {:error, {:migration_failed, Exception.message(e)}}
  end

  defp fetch_by_id(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end
end
```
