```elixir
defmodule MyApp.Tenancy.Scoper do
  @moduledoc """
  Enforces row-level multi-tenancy by injecting a `tenant_id` constraint
  into every Ecto query that touches a tenant-scoped resource. Applying
  the scoper at the boundary (controller, LiveView mount, background job
  preamble) eliminates the risk of cross-tenant data leakage caused by
  forgetting a `where` clause in an individual context function.

  Tenant-scoped schemas declare `field :tenant_id, :binary_id` and are
  identified at compile time by the `@tenanted true` module attribute.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo

  @type tenant_id :: String.t()

  @doc """
  Wraps `Repo.all/1` with a tenant scope applied to `query`.
  Raises `ArgumentError` when `query` targets a non-tenanted schema.
  """
  @spec all(Ecto.Query.t(), tenant_id()) :: [term()]
  def all(query, tenant_id) when is_binary(tenant_id) do
    query
    |> apply_scope(tenant_id)
    |> Repo.all()
  end

  @doc """
  Wraps `Repo.get/2` with a tenant scope.
  Returns `{:error, :not_found}` when the record does not exist or
  belongs to a different tenant.
  """
  @spec get(module(), term(), tenant_id()) :: {:ok, term()} | {:error, :not_found}
  def get(schema, id, tenant_id) when is_binary(tenant_id) do
    result =
      schema
      |> where([r], r.id == ^id and r.tenant_id == ^tenant_id)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Wraps `Repo.insert/2`, merging `tenant_id` into the changeset before
  persistence. Protects against callers omitting the tenant field.
  """
  @spec insert(Ecto.Changeset.t(), tenant_id(), keyword()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def insert(changeset, tenant_id, opts \\ []) when is_binary(tenant_id) do
    changeset
    |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
    |> Repo.insert(opts)
  end

  @doc """
  Wraps `Repo.delete_all/1` restricted to the given tenant scope.
  Returns the number of deleted rows.
  """
  @spec delete_all(Ecto.Query.t(), tenant_id()) :: non_neg_integer()
  def delete_all(query, tenant_id) when is_binary(tenant_id) do
    {count, _} =
      query
      |> apply_scope(tenant_id)
      |> Repo.delete_all()

    count
  end

  @doc """
  Counts records matching `query` for `tenant_id`.
  """
  @spec count(Ecto.Query.t(), tenant_id()) :: non_neg_integer()
  def count(query, tenant_id) when is_binary(tenant_id) do
    query
    |> apply_scope(tenant_id)
    |> select([r], count(r.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @spec apply_scope(Ecto.Query.t(), tenant_id()) :: Ecto.Query.t()
  defp apply_scope(query, tenant_id) do
    schema = query_schema(query)

    unless tenanted?(schema) do
      raise ArgumentError,
            "#{inspect(schema)} is not a tenanted schema; use Repo directly for non-tenanted queries"
    end

    where(query, [r], r.tenant_id == ^tenant_id)
  end

  @spec query_schema(Ecto.Query.t()) :: module()
  defp query_schema(%Ecto.Query{from: %{source: {_table, schema}}}), do: schema
  defp query_schema(schema) when is_atom(schema), do: schema

  @spec tenanted?(module()) :: boolean()
  defp tenanted?(schema) do
    function_exported?(schema, :__schema__, 1) and
      :tenant_id in schema.__schema__(:fields)
  end
end
```
