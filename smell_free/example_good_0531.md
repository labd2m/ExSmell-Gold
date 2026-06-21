```elixir
defmodule Ops.DeploymentLock do
  @moduledoc """
  Provides a distributed deployment lock using the database as a
  coordination primitive. Only one deployment may hold the lock at a time
  across all nodes. The lock is acquired with a caller-supplied identifier
  and automatically expires after a configurable TTL so a crashed deployer
  cannot block future deployments indefinitely.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Ops.DeployLock

  @type lock_id :: String.t()
  @type owner :: String.t()
  @type acquire_result :: {:ok, lock_id()} | {:error, :lock_held | Ecto.Changeset.t()}

  @default_ttl_seconds 3_600

  @doc """
  Attempts to acquire the deployment lock for `owner`. Returns a lock ID
  on success. If a valid, non-expired lock exists the call returns
  `{:error, :lock_held}`.
  """
  @spec acquire(owner(), pos_integer()) :: acquire_result()
  def acquire(owner, ttl_seconds \ @default_ttl_seconds)
      when is_binary(owner) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    Repo.transaction(fn ->
      purge_expired()

      case Repo.one(from(l in DeployLock, limit: 1)) do
        nil ->
          expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)
          attrs = %{owner: owner, expires_at: expires_at}

          case %DeployLock{} |> DeployLock.changeset(attrs) |> Repo.insert() do
            {:ok, lock} -> lock.id
            {:error, cs} -> Repo.rollback(cs)
          end

        _existing ->
          Repo.rollback(:lock_held)
      end
    end)
  end

  @doc "Releases the lock identified by `lock_id` if it is owned by `owner`."
  @spec release(lock_id(), owner()) :: :ok | {:error, :not_owner | :not_found}
  def release(lock_id, owner) when is_binary(lock_id) and is_binary(owner) do
    case Repo.get(DeployLock, lock_id) do
      nil ->
        {:error, :not_found}

      %DeployLock{owner: ^owner} = lock ->
        Repo.delete!(lock)
        :ok

      %DeployLock{} ->
        {:error, :not_owner}
    end
  end

  @doc "Returns the current lock holder, if any."
  @spec current_holder() :: {:ok, %{owner: owner(), expires_at: DateTime.t()}} | {:error, :no_lock}
  def current_holder do
    purge_expired()

    case Repo.one(from(l in DeployLock, limit: 1)) do
      nil -> {:error, :no_lock}
      lock -> {:ok, %{owner: lock.owner, expires_at: lock.expires_at}}
    end
  end

  @doc "Returns true when no valid lock is currently held."
  @spec available?() :: boolean()
  def available? do
    match?({:error, :no_lock}, current_holder())
  end

  defp purge_expired do
    Repo.delete_all(from(l in DeployLock, where: l.expires_at < ^DateTime.utc_now()))
  end
end
```
