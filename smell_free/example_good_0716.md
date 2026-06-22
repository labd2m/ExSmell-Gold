```elixir
defmodule Platform.RowLevelSecurity do
  @moduledoc """
  Composable Ecto query guards that enforce row-level access control.

  Rather than trusting callers to add ownership filters, these helpers
  are composed at the query layer and raise on misuse, making it structurally
  impossible to issue unscoped queries through the enforced API surface.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.Repo

  @type actor :: %{id: pos_integer(), roles: [atom()]}
  @type scope_result :: {:ok, struct()} | {:error, :not_found | :forbidden}

  @doc """
  Fetches a record visible to `actor`. Admins see all records; regular
  actors see only records they own (via `owner_id`) or belong to (via `account_id`).
  """
  @spec fetch_for(Ecto.Queryable.t(), pos_integer(), actor()) :: scope_result()
  def fetch_for(queryable, record_id, %{id: actor_id, roles: roles}) do
    query = if :admin in roles do
      from(r in queryable, where: r.id == ^record_id)
    else
      from(r in queryable,
        where: r.id == ^record_id and
          (r.owner_id == ^actor_id or r.account_id == ^actor_id)
      )
    end

    case Repo.one(query) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Lists records visible to `actor`, paginated.
  """
  @spec list_for(Ecto.Queryable.t(), actor(), keyword()) :: [struct()]
  def list_for(queryable, %{id: actor_id, roles: roles}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    page = Keyword.get(opts, :page, 1)

    base = if :admin in roles do
      queryable
    else
      from(r in queryable,
        where: r.owner_id == ^actor_id or r.account_id == ^actor_id
      )
    end

    from(r in base,
      order_by: [desc: r.inserted_at],
      limit: ^limit,
      offset: ^((page - 1) * limit)
    )
    |> Repo.all()
  end

  @doc """
  Verifies that `actor` may perform `action` on `record`.
  Returns `:ok` or `{:error, :forbidden}`.
  """
  @spec authorize(struct(), atom(), actor()) :: :ok | {:error, :forbidden}
  def authorize(record, action, %{id: actor_id, roles: roles}) do
    cond do
      :admin in roles -> :ok
      action == :read and readable_by?(record, actor_id) -> :ok
      action in [:update, :delete] and owned_by?(record, actor_id) -> :ok
      true -> {:error, :forbidden}
    end
  end

  @doc """
  Wraps a database write operation (changeset update/insert) with an
  ownership check. The operation is only executed if `actor` owns the record.
  """
  @spec guarded_update(struct(), actor(), (struct() -> Ecto.Changeset.t())) ::
          {:ok, struct()} | {:error, :forbidden | Ecto.Changeset.t()}
  def guarded_update(record, actor, changeset_fn) do
    with :ok <- authorize(record, :update, actor) do
      record |> changeset_fn.() |> Repo.update()
    end
  end

  @doc """
  Wraps a delete operation with ownership verification.
  """
  @spec guarded_delete(struct(), actor()) :: {:ok, struct()} | {:error, :forbidden}
  def guarded_delete(record, actor) do
    with :ok <- authorize(record, :delete, actor) do
      Repo.delete(record)
    end
  end

  defp owned_by?(%{owner_id: owner_id}, actor_id) when is_integer(owner_id) do
    owner_id == actor_id
  end

  defp owned_by?(_record, _actor_id), do: false

  defp readable_by?(%{owner_id: owner_id}, actor_id) when is_integer(owner_id) do
    owner_id == actor_id
  end

  defp readable_by?(%{account_id: account_id}, actor_id) when is_integer(account_id) do
    account_id == actor_id
  end

  defp readable_by?(%{visibility: :public}, _actor_id), do: true
  defp readable_by?(_record, _actor_id), do: false
end
```
