```elixir
defmodule Permissions.HierarchyChecker do
  @moduledoc """
  Evaluates permission checks against a role hierarchy where roles can
  inherit permissions from parent roles. Supports wildcard resource
  permissions and explicit deny overrides.
  """

  alias Permissions.{RoleStore, PermissionStore}

  @type role :: String.t()
  @type permission :: String.t()
  @type resource_type :: String.t()

  @type check_result :: %{
          granted: boolean(),
          via_role: role() | nil,
          inherited: boolean()
        }

  @spec has_permission?(String.t(), permission(), resource_type()) :: boolean()
  def has_permission?(user_id, permission, resource_type) when is_binary(user_id) do
    user_id
    |> check(permission, resource_type)
    |> Map.fetch!(:granted)
  end

  @spec check(String.t(), permission(), resource_type()) :: check_result()
  def check(user_id, permission, resource_type) when is_binary(user_id) do
    roles = RoleStore.roles_for_user(user_id)
    role_chain = expand_role_hierarchy(roles)
    evaluate_chain(role_chain, permission, resource_type)
  end

  @spec expand_role_hierarchy([role()]) :: [role()]
  def expand_role_hierarchy(roles) when is_list(roles) do
    roles
    |> Enum.flat_map(&expand_single_role(&1, MapSet.new()))
    |> Enum.uniq()
  end

  @spec evaluate_chain([role()], permission(), resource_type()) :: check_result()
  defp evaluate_chain(roles, permission, resource_type) do
    deny = Enum.find(roles, fn role ->
      PermissionStore.explicitly_denied?(role, permission, resource_type)
    end)

    case deny do
      role when not is_nil(role) ->
        %{granted: false, via_role: role, inherited: false}

      nil ->
        find_allowing_role(roles, permission, resource_type)
    end
  end

  @spec find_allowing_role([role()], permission(), resource_type()) :: check_result()
  defp find_allowing_role([], _permission, _resource_type) do
    %{granted: false, via_role: nil, inherited: false}
  end

  defp find_allowing_role([role | rest], permission, resource_type) do
    cond do
      PermissionStore.has_exact?(role, permission, resource_type) ->
        %{granted: true, via_role: role, inherited: false}

      PermissionStore.has_wildcard?(role, resource_type) ->
        %{granted: true, via_role: role, inherited: false}

      true ->
        result = find_allowing_role(rest, permission, resource_type)
        if result.granted, do: %{result | inherited: true}, else: result
    end
  end

  @spec expand_single_role(role(), MapSet.t()) :: [role()]
  defp expand_single_role(role, visited) do
    if MapSet.member?(visited, role) do
      []
    else
      new_visited = MapSet.put(visited, role)
      parent_roles = RoleStore.parent_roles(role)

      parent_expansion =
        parent_roles
        |> Enum.flat_map(&expand_single_role(&1, new_visited))

      [role | parent_expansion]
    end
  end

  @spec effective_permissions(String.t()) :: [%{permission: permission(), resource_type: resource_type(), via: role()}]
  def effective_permissions(user_id) when is_binary(user_id) do
    roles = user_id |> RoleStore.roles_for_user() |> expand_role_hierarchy()

    roles
    |> Enum.flat_map(fn role ->
      PermissionStore.list_for_role(role)
      |> Enum.map(&Map.put(&1, :via, role))
    end)
    |> Enum.uniq_by(fn p -> {p.permission, p.resource_type} end)
  end
end
```
