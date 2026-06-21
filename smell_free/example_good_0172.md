```elixir
defmodule Platform.TenantScope do
  @moduledoc """
  Composable Ecto query helpers for multi-tenant data isolation.

  Every public query function accepts a `%Tenant{}` struct as its first
  argument and injects a `tenant_id` filter, preventing cross-tenant data
  leakage at the query layer rather than relying on application-level checks.
  """

  import Ecto.Query
  alias Platform.{Repo, Tenant}

  @type tenant :: Tenant.t()
  @type query :: Ecto.Query.t()
  @type page_opts :: [page: pos_integer(), per_page: pos_integer()]

  @doc """
  Returns a base query for `schema` scoped to the given tenant.
  Use this to build further query compositions before calling `Repo.all/1`.
  """
  @spec for_tenant(Ecto.Queryable.t(), tenant()) :: query()
  def for_tenant(queryable, %Tenant{id: tenant_id}) do
    from(q in queryable, where: q.tenant_id == ^tenant_id)
  end

  @doc """
  Fetches a single record belonging to `tenant` by primary key.
  Returns `{:error, :not_found}` if no matching record exists.
  """
  @spec fetch(Ecto.Queryable.t(), tenant(), pos_integer()) ::
          {:ok, struct()} | {:error, :not_found}
  def fetch(queryable, %Tenant{} = tenant, id) when is_integer(id) do
    queryable
    |> for_tenant(tenant)
    |> where([q], q.id == ^id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Returns a paginated list of records belonging to `tenant`.
  """
  @spec list(Ecto.Queryable.t(), tenant(), page_opts()) :: [struct()]
  def list(queryable, %Tenant{} = tenant, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    queryable
    |> for_tenant(tenant)
    |> order_by([q], desc: q.inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc """
  Counts records belonging to `tenant`, with an optional additional filter.
  """
  @spec count(Ecto.Queryable.t(), tenant(), keyword()) :: non_neg_integer()
  def count(queryable, %Tenant{} = tenant, filters \\ []) do
    queryable
    |> for_tenant(tenant)
    |> apply_filters(filters)
    |> select([q], count(q.id))
    |> Repo.one()
  end

  @doc """
  Deletes all records belonging to `tenant` that match `filters`.
  Returns the count of deleted rows.
  """
  @spec delete_all(Ecto.Queryable.t(), tenant(), keyword()) :: non_neg_integer()
  def delete_all(queryable, %Tenant{} = tenant, filters \\ []) do
    {count, _} =
      queryable
      |> for_tenant(tenant)
      |> apply_filters(filters)
      |> Repo.delete_all()

    count
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:status, status} | rest]) do
    query
    |> where([q], q.status == ^status)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:inserted_after, dt} | rest]) do
    query
    |> where([q], q.inserted_at >= ^dt)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [_unknown | rest]) do
    apply_filters(query, rest)
  end
end
```
