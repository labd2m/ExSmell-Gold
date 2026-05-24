# Annotated Example — Code Smell

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `Auth.AccessControl.authorize/3`
- **Affected function(s):** `authorize/3`, `build_permission_set/1`
- **Short explanation:** `AccessControl` directly inspects internal fields of `User` (`user.locked`, `user.mfa_verified_at`, `user.role_ids`) and `Role` (`role.permissions`, `role.inherit_from`, `role.active`) to build authorization logic. This knowledge of internal structure belongs inside the `User` and `Role` modules; `AccessControl` should interact with those modules through higher-level interfaces.

```elixir
defmodule Auth.AccessControl do
  @moduledoc """
  Evaluates whether a given user is permitted to perform an action
  on a resource. Authorization decisions are logged for audit purposes.
  """

  require Logger

  alias Auth.{User, Role, AuditLog}
  alias Repo

  @mfa_validity_seconds 900

  def authorize(user_id, resource, action) do
    with {:ok, user} <- User.fetch(user_id) do
      evaluate(user, resource, action)
    end
  end

  # VALIDATION: SMELL START - Inappropriate Intimacy
  # VALIDATION: This is a smell because evaluate/3 and build_permission_set/1 directly
  # VALIDATION: read internal fields of User (locked, mfa_verified_at, role_ids) and
  # VALIDATION: Role (active, permissions, inherit_from), instead of delegating these
  # VALIDATION: checks to the User and Role modules through proper encapsulated functions.
  defp evaluate(user, resource, action) do
    cond do
      user.locked ->
        log_decision(user.id, resource, action, :denied, "account locked")
        {:error, :account_locked}

      requires_mfa?(resource, action) and not mfa_recent_enough?(user.mfa_verified_at) ->
        log_decision(user.id, resource, action, :denied, "MFA required")
        {:error, :mfa_required}

      true ->
        permission_set = build_permission_set(user)
        required = "#{resource}:#{action}"

        if MapSet.member?(permission_set, required) or
             MapSet.member?(permission_set, "#{resource}:*") or
             MapSet.member?(permission_set, "*:*") do
          log_decision(user.id, resource, action, :allowed, "permission matched")
          :ok
        else
          log_decision(user.id, resource, action, :denied, "permission not found")
          {:error, :forbidden}
        end
    end
  end

  defp build_permission_set(user) do
    user.role_ids
    |> Enum.map(&Role.fetch!/1)
    |> Enum.filter(fn role -> role.active end)
    |> Enum.flat_map(fn role ->
      parent_permissions =
        case role.inherit_from do
          nil -> []
          parent_id ->
            parent = Role.fetch!(parent_id)
            if parent.active, do: parent.permissions, else: []
        end

      role.permissions ++ parent_permissions
    end)
    |> MapSet.new()
  end

  defp mfa_recent_enough?(nil), do: false

  defp mfa_recent_enough?(mfa_verified_at) do
    diff = DateTime.diff(DateTime.utc_now(), mfa_verified_at, :second)
    diff <= @mfa_validity_seconds
  end
  # VALIDATION: SMELL END

  defp requires_mfa?(resource, action) do
    mfa_required_resources = Application.get_env(:auth, :mfa_required_resources, [])
    "#{resource}:#{action}" in mfa_required_resources
  end

  defp log_decision(user_id, resource, action, decision, reason) do
    %AuditLog{
      user_id: user_id,
      resource: resource,
      action: action,
      decision: decision,
      reason: reason,
      occurred_at: DateTime.utc_now()
    }
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> Logger.error("Failed to write audit log for user #{user_id}")
    end
  end

  def list_user_permissions(user_id) do
    with {:ok, user} <- User.fetch(user_id) do
      permissions =
        user
        |> build_permission_set()
        |> MapSet.to_list()
        |> Enum.sort()

      {:ok, permissions}
    end
  end
end
```
