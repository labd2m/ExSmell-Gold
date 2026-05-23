```elixir
defmodule UserPolicy do
  @moduledoc """
  Enforces access-control rules for user management operations across organisations.
  """

  alias UserManagement.{User, Role, OrgOverride, PermissionSet, AuditLog}

  @super_admin_role :super_admin
  @admin_roles [:admin, :org_admin]

  def can_view_user?(%User{role: @super_admin_role}, _target), do: true

  def can_view_user?(%User{} = actor, %User{} = target) do
    actor.org_id == target.org_id or
      Enum.member?(@admin_roles, actor.role)
  end

  def can_edit_user?(%User{role: @super_admin_role}, _target), do: true

  def can_edit_user?(%User{} = actor, %User{} = target) do
    base_permissions =
      case Role.fetch_permissions(actor.role) do
        {:ok, perms} -> perms
        _ -> %PermissionSet{}
      end

    effective_permissions =
      case OrgOverride.fetch(actor.org_id, actor.id) do
        {:ok, override} -> PermissionSet.merge(base_permissions, override.permissions)
        _ -> base_permissions
      end

    in_same_org = actor.org_id == target.org_id
    has_permission = PermissionSet.grants?(effective_permissions, :edit_users)
    higher_rank = Role.rank(actor.role) > Role.rank(target.role)

    in_same_org and has_permission and higher_rank
  end

  def can_delete_user?(%User{role: @super_admin_role}, _target), do: true

  def can_delete_user?(%User{} = actor, %User{} = target) do
    base_permissions =
      case Role.fetch_permissions(actor.role) do
        {:ok, perms} -> perms
        _ -> %PermissionSet{}
      end

    effective_permissions =
      case OrgOverride.fetch(actor.org_id, actor.id) do
        {:ok, override} -> PermissionSet.merge(base_permissions, override.permissions)
        _ -> base_permissions
      end

    in_same_org = actor.org_id == target.org_id
    has_permission = PermissionSet.grants?(effective_permissions, :delete_users)
    higher_rank = Role.rank(actor.role) > Role.rank(target.role)

    in_same_org and has_permission and higher_rank and not target.is_owner
  end

  def can_invite_user?(%User{role: @super_admin_role}, _org_id), do: true

  def can_invite_user?(%User{} = actor, org_id) do
    actor.org_id == org_id and Enum.member?(@admin_roles, actor.role)
  end

  def can_assign_role?(%User{role: @super_admin_role}, _target, _new_role), do: true

  def can_assign_role?(%User{} = actor, %User{} = target, new_role) do
    in_same_org = actor.org_id == target.org_id
    can_edit = can_edit_user?(actor, target)
    new_role_rank = Role.rank(new_role)
    actor_rank = Role.rank(actor.role)

    in_same_org and can_edit and new_role_rank < actor_rank
  end

  def audit_decision(actor, action, target, result) do
    AuditLog.record(%{
      actor_id: actor.id,
      actor_role: actor.role,
      action: action,
      target_id: target.id,
      outcome: if(result, do: :allowed, else: :denied),
      recorded_at: DateTime.utc_now()
    })

    result
  end
end
```
