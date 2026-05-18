```elixir
defmodule UserManagement.RoleChecker do
  @moduledoc """
  Centralises role-based access control decisions for the user management
  domain. Roles are hierarchical; higher roles implicitly inherit lower ones.
  """

  @role_hierarchy [:viewer, :editor, :manager, :admin, :super_admin]

  defmacro has_permission?(role, required_roles) do
    quote do
      user_role = unquote(role)
      allowed = unquote(required_roles)
      hierarchy = unquote(@role_hierarchy)

      user_index = Enum.find_index(hierarchy, &(&1 == user_role)) || -1

      Enum.any?(allowed, fn req ->
        req_index = Enum.find_index(hierarchy, &(&1 == req)) || 999
        user_index >= req_index
      end)
    end
  end

  def can_read_user?(role), do: check(role, [:viewer])
  def can_edit_user?(role), do: check(role, [:editor])
  def can_delete_user?(role), do: check(role, [:manager])
  def can_manage_roles?(role), do: check(role, [:admin])
  def can_access_super_tools?(role), do: check(role, [:super_admin])

  defp check(role, required) do
    require UserManagement.RoleChecker
    UserManagement.RoleChecker.has_permission?(role, required)
  end

  def permitted_actions(role) do
    all_actions = [
      {:read_user, [:viewer]},
      {:edit_user, [:editor]},
      {:delete_user, [:manager]},
      {:manage_roles, [:admin]},
      {:access_super_tools, [:super_admin]}
    ]

    for {action, required} <- all_actions,
        check(role, required),
        do: action
  end

  def effective_role_level(role) do
    Enum.find_index(@role_hierarchy, &(&1 == role)) || -1
  end

  def roles_below(role) do
    level = effective_role_level(role)
    Enum.take(@role_hierarchy, level)
  end

  def roles_at_or_above(role) do
    level = effective_role_level(role)
    Enum.drop(@role_hierarchy, level)
  end

  def can_manage?(actor_role, target_role) do
    actor_level = effective_role_level(actor_role)
    target_level = effective_role_level(target_role)
    actor_level > target_level
  end

  def validate_role_change(actor, target, new_role) do
    cond do
      not can_manage_roles?(actor.role) ->
        {:error, :insufficient_permissions}

      not can_manage?(actor.role, new_role) ->
        {:error, :cannot_assign_equal_or_higher_role}

      actor.id == target.id ->
        {:error, :cannot_change_own_role}

      true ->
        :ok
    end
  end

  def list_valid_roles_for(actor_role) do
    roles_below(actor_role)
  end
end
```
