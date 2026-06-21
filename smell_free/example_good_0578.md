```elixir
defmodule Platform.ReplicaRouter do
  @moduledoc """
  Routes Ecto read queries to a pool of read replicas while directing
  writes to the primary database.

  The router selects replicas using round-robin assignment, tracked via
  an atomic counter, so no GenServer serializes reads. Write operations
  always use the primary repo regardless of the caller's repo preference.
  """

  alias Platform.{Repo, ReplicaRepo}

  @type queryable :: Ecto.Queryable.t()
  @type result :: {:ok, term()} | {:error, term()}

  @replicas [ReplicaRepo.One, ReplicaRepo.Two]
  @replica_count length(@replicas)

  @doc """
  Executes a read query against a replica. Falls back to primary on error.
  """
  @spec all(queryable(), keyword()) :: [struct()]
  def all(queryable, opts \\ []) do
    select_replica().all(queryable, opts)
  rescue
    _ -> Repo.all(queryable, opts)
  end

  @doc """
  Fetches a single record from a replica.
  """
  @spec one(queryable(), keyword()) :: struct() | nil
  def one(queryable, opts \\ []) do
    select_replica().one(queryable, opts)
  rescue
    _ -> Repo.one(queryable, opts)
  end

  @doc """
  Gets a record by primary key from a replica.
  """
  @spec get(module(), term(), keyword()) :: struct() | nil
  def get(schema, id, opts \\ []) do
    select_replica().get(schema, id, opts)
  rescue
    _ -> Repo.get(schema, id, opts)
  end

  @doc """
  Checks existence against a replica.
  """
  @spec exists?(queryable()) :: boolean()
  def exists?(queryable) do
    select_replica().exists?(queryable)
  rescue
    _ -> Repo.exists?(queryable)
  end

  @doc "Aggregates a query against a replica."
  @spec aggregate(queryable(), atom(), atom(), keyword()) :: term()
  def aggregate(queryable, aggregate, field, opts \\ []) do
    select_replica().aggregate(queryable, aggregate, field, opts)
  rescue
    _ -> Repo.aggregate(queryable, aggregate, field, opts)
  end

  @doc """
  Executes a write operation (insert, update, delete) against the primary.
  Provided as a convenience so callers need not import `Repo` separately.
  """
  @spec insert(Ecto.Changeset.t(), keyword()) :: result()
  def insert(changeset, opts \\ []), do: Repo.insert(changeset, opts)

  @doc "Updates a record against the primary."
  @spec update(Ecto.Changeset.t(), keyword()) :: result()
  def update(changeset, opts \\ []), do: Repo.update(changeset, opts)

  @doc "Deletes a record against the primary."
  @spec delete(struct() | Ecto.Changeset.t(), keyword()) :: result()
  def delete(struct_or_changeset, opts \\ []), do: Repo.delete(struct_or_changeset, opts)

  @doc "Runs a transaction against the primary."
  @spec transaction((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts \\ []), do: Repo.transaction(fun, opts)

  @doc "Returns the replica currently selected by round-robin for diagnostics."
  @spec current_replica() :: module()
  def current_replica do
    idx = :atomics.get(counter(), 1)
    Enum.at(@replicas, rem(idx, @replica_count))
  end

  defp select_replica do
    idx = :atomics.add_get(counter(), 1, 1)
    Enum.at(@replicas, rem(idx, @replica_count))
  end

  defp counter do
    case :persistent_term.get({__MODULE__, :counter}, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put({__MODULE__, :counter}, ref)
        ref

      ref ->
        ref
    end
  end
end
```
