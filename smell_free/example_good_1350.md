```elixir
defmodule Multitenancy.PrefixRepo do
  @moduledoc """
  An Ecto repository wrapper that transparently scopes all queries to a
  per-tenant PostgreSQL schema prefix. The prefix is resolved from an
  explicit `Multitenancy.Tenant` struct rather than process state,
  making the scope visible at every call site.
  """

  alias Multitenancy.Tenant

  @repo Multitenancy.Repo

  @type query_result(t) :: {:ok, t} | {:error, Ecto.Changeset.t()}

  @spec all(Tenant.t(), Ecto.Queryable.t()) :: list(term())
  def all(%Tenant{schema_prefix: prefix}, queryable) do
    @repo.all(queryable, prefix: prefix)
  end

  @spec one(Tenant.t(), Ecto.Queryable.t()) :: term() | nil
  def one(%Tenant{schema_prefix: prefix}, queryable) do
    @repo.one(queryable, prefix: prefix)
  end

  @spec get(Tenant.t(), Ecto.Queryable.t(), integer()) :: term() | nil
  def get(%Tenant{schema_prefix: prefix}, queryable, id) when is_integer(id) do
    @repo.get(queryable, id, prefix: prefix)
  end

  @spec get_by(Tenant.t(), Ecto.Queryable.t(), keyword()) :: term() | nil
  def get_by(%Tenant{schema_prefix: prefix}, queryable, clauses) when is_list(clauses) do
    @repo.get_by(queryable, clauses, prefix: prefix)
  end

  @spec insert(Tenant.t(), Ecto.Changeset.t()) :: query_result(term())
  def insert(%Tenant{schema_prefix: prefix}, changeset) do
    @repo.insert(changeset, prefix: prefix)
  end

  @spec update(Tenant.t(), Ecto.Changeset.t()) :: query_result(term())
  def update(%Tenant{schema_prefix: prefix}, changeset) do
    @repo.update(changeset, prefix: prefix)
  end

  @spec delete(Tenant.t(), struct()) :: query_result(term())
  def delete(%Tenant{schema_prefix: prefix}, struct) do
    @repo.delete(struct, prefix: prefix)
  end

  @spec transaction(Tenant.t(), (-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(%Tenant{schema_prefix: prefix}, fun) when is_function(fun, 0) do
    @repo.transaction(fn -> fun.() end, prefix: prefix)
  end
end

defmodule Multitenancy.Tenant do
  @moduledoc """
  Value object representing a resolved tenant with its schema prefix.
  """

  @enforce_keys [:id, :slug, :schema_prefix]
  defstruct [:id, :slug, :schema_prefix, :display_name, :plan]

  @type t :: %__MODULE__{
          id: integer(),
          slug: String.t(),
          schema_prefix: String.t(),
          display_name: String.t() | nil,
          plan: String.t() | nil
        }

  @spec build(integer(), String.t(), keyword()) :: {:ok, t()} | {:error, :invalid_tenant}
  def build(id, slug, opts \\ []) when is_integer(id) and is_binary(slug) do
    if valid_slug?(slug) do
      {:ok,
       %__MODULE__{
         id: id,
         slug: slug,
         schema_prefix: "tenant_#{slug}",
         display_name: Keyword.get(opts, :display_name),
         plan: Keyword.get(opts, :plan)
       }}
    else
      {:error, :invalid_tenant}
    end
  end

  @spec schema_prefix(t()) :: String.t()
  def schema_prefix(%__MODULE__{schema_prefix: p}), do: p

  defp valid_slug?(slug) do
    Regex.match?(~r/^[a-z0-9\-]{2,40}$/, slug)
  end
end

defmodule Multitenancy.Provisioner do
  @moduledoc """
  Creates and tears down per-tenant PostgreSQL schemas using Ecto migrations.
  """

  alias Multitenancy.{Repo, Tenant}

  @spec provision(Tenant.t()) :: :ok | {:error, term()}
  def provision(%Tenant{schema_prefix: prefix}) do
    with :ok <- create_schema(prefix) do
      run_migrations(prefix)
    end
  end

  @spec deprovision(Tenant.t()) :: :ok | {:error, term()}
  def deprovision(%Tenant{schema_prefix: prefix}) do
    Repo.query("DROP SCHEMA IF EXISTS #{prefix} CASCADE")
    |> case do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp create_schema(prefix) do
    case Repo.query("CREATE SCHEMA IF NOT EXISTS #{prefix}") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp run_migrations(prefix) do
    Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, prefix: prefix)
    :ok
  rescue
    err -> {:error, Exception.message(err)}
  end

  defp migrations_path do
    Application.app_dir(:multitenancy, "priv/repo/tenant_migrations")
  end
end
```
