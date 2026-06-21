```elixir
defmodule Platform.SoftDelete do
  @moduledoc """
  Composable Ecto query helpers and changeset functions for soft-delete support.

  Schemas using soft delete must have a `deleted_at` field of type `:utc_datetime`.
  All helpers are pure functions that compose with standard Ecto query pipelines.
  """

  import Ecto.Query
  import Ecto.Changeset

  alias Platform.Repo

  @type schema :: module()
  @type queryable :: Ecto.Queryable.t()

  @doc """
  Returns a query that excludes soft-deleted records.
  This is the standard filter for all user-facing queries.
  """
  @spec active(queryable()) :: Ecto.Query.t()
  def active(queryable) do
    from(q in queryable, where: is_nil(q.deleted_at))
  end

  @doc """
  Returns a query that includes only soft-deleted records.
  """
  @spec deleted(queryable()) :: Ecto.Query.t()
  def deleted(queryable) do
    from(q in queryable, where: not is_nil(q.deleted_at))
  end

  @doc """
  Returns a query that includes both active and soft-deleted records.
  """
  @spec with_deleted(queryable()) :: Ecto.Query.t()
  def with_deleted(queryable), do: from(q in queryable)

  @doc """
  Soft-deletes a record by setting its `deleted_at` timestamp.
  Returns `{:ok, record}` or `{:error, changeset}`.
  """
  @spec soft_delete(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def soft_delete(%{deleted_at: nil} = record) do
    record
    |> deletion_changeset()
    |> Repo.update()
  end

  def soft_delete(%{deleted_at: _already_deleted} = record) do
    {:ok, record}
  end

  @doc """
  Restores a soft-deleted record by clearing its `deleted_at` field.
  Returns `{:ok, record}` or `{:error, changeset}`.
  """
  @spec restore(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def restore(%{deleted_at: nil} = record) do
    {:ok, record}
  end

  def restore(record) do
    record
    |> change(%{deleted_at: nil})
    |> Repo.update()
  end

  @doc """
  Permanently deletes all soft-deleted records older than `older_than` days.
  Returns the count of permanently removed rows.
  """
  @spec purge_old(queryable(), pos_integer()) :: non_neg_integer()
  def purge_old(queryable, older_than_days) when is_integer(older_than_days) and older_than_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_days, :day)

    {count, _} =
      queryable
      |> deleted()
      |> where([q], q.deleted_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  @doc """
  Produces a changeset that marks a record as deleted.
  Suitable for use in `Ecto.Multi` pipelines.
  """
  @spec deletion_changeset(struct()) :: Ecto.Changeset.t()
  def deletion_changeset(record) do
    change(record, %{deleted_at: DateTime.utc_now()})
  end
end
```
