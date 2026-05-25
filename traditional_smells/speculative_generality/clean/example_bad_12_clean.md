```elixir
defmodule Auth.AccessPolicy do
  @moduledoc """
  Resolves and enforces access permissions for users across protected resources.
  Provides role- and account-tier-based access control for the API layer.
  """

  alias Auth.{User, Resource, AuditLog}
  alias Auth.Repo

  @public_resources [:home, :docs, :status_page]

  def authorize(user_id, resource_key) do
    user     = Repo.get!(User, user_id)
    resource = Repo.get_by!(Resource, key: resource_key)

    cond do
      resource.key in @public_resources ->
        :ok

      user.status != :active ->
        {:error, :account_inactive}

      true ->
        permissions = resolve_permissions(user)
        check_permission(permissions, resource.required_permission)
    end
  end

  def resolve_permissions(%User{account_type: account_type} = _user) do
    case account_type do
      :free       -> %{read: true, write: true, admin: false, export: false}
      :basic      -> %{read: true, write: true, admin: false, export: false}
      :pro        -> %{read: true, write: true, admin: false, export: false}
      :enterprise -> %{read: true, write: true, admin: false, export: false}
      _           -> %{read: true, write: true, admin: false, export: false}
    end
  end

  def enforce_rate_limit(user_id, action) do
    user = Repo.get!(User, user_id)
    key  = "rate:#{user_id}:#{action}"

    current = :ets.lookup(:rate_limit_store, key)

    case current do
      [{^key, count}] when count >= per_action_limit(action) ->
        {:error, :rate_limit_exceeded}

      [{^key, count}] ->
        :ets.insert(:rate_limit_store, {key, count + 1})
        :ok

      [] ->
        :ets.insert(:rate_limit_store, {key, 1})
        :ok
    end
  end

  def grant_temporary_access(user_id, resource_key, duration_minutes) do
    expires_at = DateTime.add(DateTime.utc_now(), duration_minutes * 60, :second)

    AuditLog.record!(:temporary_grant, %{
      user_id:      user_id,
      resource_key: resource_key,
      expires_at:   expires_at,
      granted_at:   DateTime.utc_now()
    })

    {:ok, %{user_id: user_id, resource_key: resource_key, expires_at: expires_at}}
  end

  def revoke_access(user_id, resource_key) do
    AuditLog.record!(:revoke, %{
      user_id:      user_id,
      resource_key: resource_key,
      revoked_at:   DateTime.utc_now()
    })

    :ok
  end

  def list_user_permissions(user_id) do
    user = Repo.get!(User, user_id)
    resolve_permissions(user)
  end

  def audit_access_log(user_id, from_dt, to_dt) do
    AuditLog
    |> Repo.all()
    |> Enum.filter(fn entry ->
      entry.user_id == user_id and
        DateTime.compare(entry.occurred_at, from_dt) in [:gt, :eq] and
        DateTime.compare(entry.occurred_at, to_dt) in [:lt, :eq]
    end)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
  end

  def resource_exists?(resource_key) do
    case Repo.get_by(Resource, key: resource_key) do
      nil -> false
      _   -> true
    end
  end

  def bulk_authorize(user_id, resource_keys) do
    Enum.map(resource_keys, fn key ->
      {key, authorize(user_id, key)}
    end)
  end


  defp check_permission(permissions, required) do
    if Map.get(permissions, required, false) do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp per_action_limit(:read),   do: 1000
  defp per_action_limit(:write),  do: 200
  defp per_action_limit(:export), do: 10
  defp per_action_limit(_),       do: 50
end
```
