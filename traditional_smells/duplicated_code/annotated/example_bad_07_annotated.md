# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `UserManagement.Permissions.grant_role/2` and `UserManagement.Permissions.revoke_role/2` |
| **Affected functions** | `grant_role/2`, `revoke_role/2` |
| **Short explanation** | Both functions duplicate the logic for checking that a role string is in the list of allowed roles and that the user account is in an active state. If the list of valid roles or active-status conditions change, developers must update two separate code blocks. |

```elixir
defmodule UserManagement.Permissions do
  @moduledoc """
  Controls role-based access assignments for platform users.
  Supports granting, revoking, and inspecting role memberships.
  """

  alias UserManagement.Repo
  alias UserManagement.User
  alias UserManagement.RoleAssignment
  alias UserManagement.AuditLog

  @valid_roles ~w(admin editor viewer billing_manager support_agent)

  @doc """
  Grants the given role to a user. The user must be active and
  the role must be a recognized platform role.
  """
  def grant_role(%User{} = user, role) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the two-part guard (role in valid roles,
    # user status is active) is duplicated verbatim in revoke_role/2.
    # If a new user status (e.g., :pending_verification) should also be allowed,
    # or if roles are reorganized, the change must be made in both functions.
    cond do
      role not in @valid_roles ->
        {:error, {:invalid_role, role}}

      user.status != :active ->
        {:error, {:user_not_active, user.id}}

      true ->
        :proceed
    end
    # VALIDATION: SMELL END
    |> case do
      :proceed ->
        if Repo.exists?(RoleAssignment, user_id: user.id, role: role) do
          {:error, :role_already_assigned}
        else
          assignment = %RoleAssignment{user_id: user.id, role: role, granted_at: DateTime.utc_now()}
          Repo.insert(assignment)
          AuditLog.record(:role_granted, %{user_id: user.id, role: role})
          {:ok, assignment}
        end

      error ->
        error
    end
  end

  @doc """
  Revokes the given role from a user. The user must be active and
  the role must be a recognized platform role.
  """
  def revoke_role(%User{} = user, role) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because this cond block is identical to
    # the one in grant_role/2.
    cond do
      role not in @valid_roles ->
        {:error, {:invalid_role, role}}

      user.status != :active ->
        {:error, {:user_not_active, user.id}}

      true ->
        :proceed
    end
    # VALIDATION: SMELL END
    |> case do
      :proceed ->
        case Repo.get_by(RoleAssignment, user_id: user.id, role: role) do
          nil ->
            {:error, :role_not_assigned}

          assignment ->
            Repo.delete(assignment)
            AuditLog.record(:role_revoked, %{user_id: user.id, role: role})
            {:ok, :revoked}
        end

      error ->
        error
    end
  end

  @doc """
  Returns the list of roles currently assigned to a user.
  """
  def list_roles(%User{} = user) do
    Repo.all_by(RoleAssignment, user_id: user.id)
    |> Enum.map(& &1.role)
  end

  @doc """
  Returns true if the user has the given role, false otherwise.
  """
  def has_role?(%User{} = user, role) do
    Repo.exists?(RoleAssignment, user_id: user.id, role: role)
  end

  @doc """
  Returns all users that hold a specific role.
  """
  def users_with_role(role) when role in @valid_roles do
    Repo.all_by(RoleAssignment, role: role)
    |> Enum.map(& &1.user_id)
    |> then(&Repo.get_all(User, ids: &1))
  end

  def users_with_role(role), do: {:error, {:invalid_role, role}}
end
```
