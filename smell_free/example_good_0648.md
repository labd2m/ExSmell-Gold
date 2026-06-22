```elixir
defmodule Persistence.SoftDelete do
  @moduledoc """
  Provides composable query helpers and changeset utilities for implementing
  soft-deletion across Ecto schemas. Deleted records have their `deleted_at`
  field set to the current timestamp rather than being physically removed.
  The `scope_active/1` and `scope_deleted/1` helpers integrate cleanly with
  existing query pipelines using `|>` without hidden behaviour or overriding
  `Repo` callbacks, keeping the mechanics visible at every call site.
  """

  import Ecto.Query
  import Ecto.Changeset

  @type queryable :: Ecto.Queryable.t()

  @doc """
  Filters `queryable` to return only records where `deleted_at` is nil.
  Chain before other filters to always exclude soft-deleted rows:

      User |> SoftDelete.scope_active() |> where([u], u.role == :admin) |> Repo.all()
  """
  @spec scope_active(queryable()) :: Ecto.Query.t()
  def scope_active(queryable) do
    where(queryable, [r], is_nil(r.deleted_at))
  end

  @doc """
  Filters `queryable` to return only records where `deleted_at` is not nil.
  """
  @spec scope_deleted(queryable()) :: Ecto.Query.t()
  def scope_deleted(queryable) do
    where(queryable, [r], not is_nil(r.deleted_at))
  end

  @doc """
  Filters `queryable` to include all records regardless of deletion status.
  Explicitly documents intent when a query should cross the deletion boundary.
  """
  @spec scope_all(queryable()) :: Ecto.Query.t()
  def scope_all(queryable), do: queryable

  @doc """
  Returns a changeset that sets `deleted_at` to the current UTC time.
  Apply and `Repo.update/1` to perform a soft delete.
  """
  @spec delete_changeset(struct()) :: Ecto.Changeset.t()
  def delete_changeset(record) do
    record
    |> change(%{deleted_at: DateTime.utc_now()})
    |> validate_change(:deleted_at, fn :deleted_at, _value ->
      if Map.get(record, :deleted_at) != nil do
        [deleted_at: "record is already deleted"]
      else
        []
      end
    end)
  end

  @doc """
  Returns a changeset that clears `deleted_at`, restoring the record.
  """
  @spec restore_changeset(struct()) :: Ecto.Changeset.t()
  def restore_changeset(record) do
    record
    |> change(%{deleted_at: nil})
    |> validate_change(:deleted_at, fn :deleted_at, _value ->
      if Map.get(record, :deleted_at) == nil do
        [deleted_at: "record is not deleted"]
      else
        []
      end
    end)
  end

  @doc """
  Returns `true` when `record` has been soft-deleted.
  """
  @spec deleted?(struct()) :: boolean()
  def deleted?(%{deleted_at: nil}), do: false
  def deleted?(%{deleted_at: %DateTime{}}), do: true
  def deleted?(_record), do: false

  @doc """
  Permanently deletes all soft-deleted records from `queryable` that were
  deleted more than `days_old` days ago. Returns the count of purged rows.
  """
  @spec purge_old(queryable(), module(), pos_integer()) :: {:ok, non_neg_integer()}
  def purge_old(queryable, repo, days_old \\ 90) when is_integer(days_old) and days_old > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days_old * 86_400, :second)

    {count, _} =
      queryable
      |> scope_deleted()
      |> where([r], r.deleted_at < ^cutoff)
      |> repo.delete_all()

    {:ok, count}
  end

  @doc """
  Counts soft-deleted records in `queryable` that are older than `days_old` days.
  Useful for admin dashboards showing purge candidates.
  """
  @spec count_purgeable(queryable(), module(), pos_integer()) :: non_neg_integer()
  def count_purgeable(queryable, repo, days_old \\ 90) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_old * 86_400, :second)

    queryable
    |> scope_deleted()
    |> where([r], r.deleted_at < ^cutoff)
    |> repo.aggregate(:count, :id)
  end
end
```
