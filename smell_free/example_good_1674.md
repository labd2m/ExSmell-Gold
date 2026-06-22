```elixir
defmodule Locking.LeaseManager do
  @moduledoc """
  Manages short-lived exclusive leases on named resources. A lease grants
  the holder temporary ownership for a configured TTL, after which it
  expires automatically. Lease holders may renew before expiry.
  """

  alias Locking.{Repo, Lease}
  import Ecto.Query

  @type resource_key :: String.t()
  @type holder_id :: String.t()
  @type lease_result :: {:ok, Lease.t()} | {:error, :already_leased | :not_found | :not_owner | Ecto.Changeset.t()}

  @default_ttl_seconds 30

  @spec acquire(resource_key(), holder_id(), keyword()) :: lease_result()
  def acquire(resource_key, holder_id, opts \\ [])
      when is_binary(resource_key) and is_binary(holder_id) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

    Repo.transaction(fn ->
      case active_lease(resource_key) do
        nil ->
          %Lease{}
          |> Lease.creation_changeset(%{
            resource_key: resource_key,
            holder_id: holder_id,
            expires_at: expires_at
          })
          |> Repo.insert!()

        _existing ->
          Repo.rollback(:already_leased)
      end
    end)
    |> case do
      {:ok, lease} -> {:ok, lease}
      {:error, :already_leased} -> {:error, :already_leased}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec renew(resource_key(), holder_id(), keyword()) :: lease_result()
  def renew(resource_key, holder_id, opts \\ []) when is_binary(resource_key) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    new_expiry = DateTime.add(DateTime.utc_now(), ttl, :second)

    case Repo.get_by(Lease, resource_key: resource_key, holder_id: holder_id, revoked: false) do
      nil ->
        {:error, :not_found}

      lease ->
        lease
        |> Lease.renewal_changeset(%{expires_at: new_expiry})
        |> Repo.update()
    end
  end

  @spec release(resource_key(), holder_id()) :: :ok | {:error, :not_found | :not_owner}
  def release(resource_key, holder_id) when is_binary(resource_key) do
    case active_lease(resource_key) do
      nil ->
        {:error, :not_found}

      %Lease{holder_id: ^holder_id} = lease ->
        lease |> Lease.revocation_changeset() |> Repo.update()
        :ok

      %Lease{} ->
        {:error, :not_owner}
    end
  end

  @spec held_by?(resource_key(), holder_id()) :: boolean()
  def held_by?(resource_key, holder_id) when is_binary(resource_key) do
    now = DateTime.utc_now()

    from(l in Lease,
      where:
        l.resource_key == ^resource_key and
          l.holder_id == ^holder_id and
          l.revoked == false and
          l.expires_at > ^now,
      limit: 1
    )
    |> Repo.exists?()
  end

  @spec expired_leases() :: [Lease.t()]
  def expired_leases do
    now = DateTime.utc_now()

    from(l in Lease,
      where: l.expires_at <= ^now and l.revoked == false
    )
    |> Repo.all()
  end

  @spec purge_expired() :: {:ok, non_neg_integer()}
  def purge_expired do
    now = DateTime.utc_now()

    {count, _} =
      from(l in Lease, where: l.expires_at <= ^now and l.revoked == false)
      |> Repo.update_all(set: [revoked: true])

    {:ok, count}
  end

  @spec active_lease(resource_key()) :: Lease.t() | nil
  defp active_lease(resource_key) do
    now = DateTime.utc_now()

    from(l in Lease,
      where:
        l.resource_key == ^resource_key and
          l.revoked == false and
          l.expires_at > ^now,
      lock: "FOR UPDATE",
      limit: 1
    )
    |> Repo.one()
  end
end
```
