```elixir
defmodule MultiTenant.Repo do
  @moduledoc """
  Thin wrapper around Ecto.Repo that enforces tenant schema prefixes on
  every operation in a multi-tenant PostgreSQL deployment using schema-based
  isolation.

  The tenant prefix is supplied per-call through an opts keyword, never
  read from global process state, making concurrent multi-tenant usage safe.
  """

  alias MultiTenant.Repo.{PrefixResolver, BaseRepo}

  @type tenant_opts :: [tenant_id: String.t()]

  @doc """
  Fetches a single record by primary key within the tenant's schema.
  """
  @spec get(module(), term(), tenant_opts()) :: struct() | nil
  def get(schema, id, opts) when is_atom(schema) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.get(schema, id, prefix: prefix)
  end

  @doc """
  Fetches a single record matching keyword filters within the tenant's schema.
  """
  @spec get_by(module(), keyword(), tenant_opts()) :: struct() | nil
  def get_by(schema, clauses, opts) when is_atom(schema) and is_list(clauses) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.get_by(schema, clauses, prefix: prefix)
  end

  @doc """
  Returns all records for a queryable within the tenant's schema.
  """
  @spec all(Ecto.Queryable.t(), tenant_opts()) :: [struct()]
  def all(queryable, opts) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.all(queryable, prefix: prefix)
  end

  @doc """
  Inserts a changeset within the tenant's schema.
  """
  @spec insert(Ecto.Changeset.t(), tenant_opts()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def insert(%Ecto.Changeset{} = changeset, opts) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.insert(changeset, prefix: prefix)
  end

  @doc """
  Updates a changeset within the tenant's schema.
  """
  @spec update(Ecto.Changeset.t(), tenant_opts()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{} = changeset, opts) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.update(changeset, prefix: prefix)
  end

  @doc """
  Deletes a struct from the tenant's schema.
  """
  @spec delete(struct(), tenant_opts()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def delete(%_{} = struct, opts) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.delete(struct, prefix: prefix)
  end

  @doc """
  Runs a function inside a database transaction scoped to the tenant schema.
  """
  @spec transaction(tenant_opts(), (() -> term())) :: {:ok, term()} | {:error, term()}
  def transaction(opts, fun) when is_function(fun, 0) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.transaction(fun, prefix: prefix)
  end

  @doc """
  Executes a query with an aggregate function within the tenant's schema.
  """
  @spec aggregate(Ecto.Queryable.t(), atom(), atom(), tenant_opts()) :: term()
  def aggregate(queryable, aggregate, field, opts)
      when is_atom(aggregate) and is_atom(field) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.aggregate(queryable, aggregate, field, prefix: prefix)
  end

  @doc """
  Checks whether any record matching a queryable exists in the tenant schema.
  """
  @spec exists?(Ecto.Queryable.t(), tenant_opts()) :: boolean()
  def exists?(queryable, opts) do
    prefix = PrefixResolver.resolve!(Keyword.fetch!(opts, :tenant_id))
    BaseRepo.exists?(queryable, prefix: prefix)
  end
end

defmodule MultiTenant.Repo.PrefixResolver do
  @moduledoc """
  Resolves a tenant ID to its PostgreSQL schema prefix.

  Schema names follow the pattern `tenant_<sanitised_id>`. The sanitisation
  strips non-alphanumeric characters to prevent SQL injection via the prefix.
  """

  @prefix_namespace "tenant"

  @spec resolve!(String.t()) :: String.t()
  def resolve!(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    sanitised = String.replace(tenant_id, ~r/[^a-z0-9_]/, "")

    if sanitised == "" do
      raise ArgumentError, "tenant_id #{inspect(tenant_id)} produces an empty schema prefix"
    end

    "#{@prefix_namespace}_#{sanitised}"
  end

  def resolve!(other) do
    raise ArgumentError, "tenant_id must be a non-empty binary, got: #{inspect(other)}"
  end

  @spec valid_tenant_id?(String.t()) :: boolean()
  def valid_tenant_id?(tenant_id) when is_binary(tenant_id) do
    Regex.match?(~r/\A[a-z0-9_]{1,63}\z/, tenant_id)
  end

  def valid_tenant_id?(_), do: false
end
```
