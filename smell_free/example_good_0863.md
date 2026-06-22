```elixir
defmodule Platform.HierarchicalRbac do
  @moduledoc """
  A hierarchical role-based access control system where roles inherit all
  permissions from their parent roles.

  The role graph is a directed acyclic tree: `admin` inherits from `editor`,
  which inherits from `viewer`. Permission checks traverse upward through
  the hierarchy so that a higher-level role automatically passes all checks
  valid for lower-level roles.
  """

  @type role :: atom()
  @type permission :: atom()
  @type subject :: %{id: pos_integer(), roles: [role()]}

  @role_hierarchy %{
    admin: [:editor],
    editor: [:moderator],
    moderator: [:contributor],
    contributor: [:viewer],
    viewer: [],
    billing_manager: [:viewer],
    support: [:viewer]
  }

  @role_permissions %{
    viewer: [:read_content, :read_profile],
    contributor: [:create_content, :edit_own_content],
    moderator: [:edit_any_content, :delete_content, :ban_user],
    editor: [:publish_content, :manage_tags],
    admin: [:manage_users, :manage_roles, :manage_billing, :access_admin],
    billing_manager: [:manage_billing, :read_invoices],
    support: [:read_profile, :impersonate_user, :view_audit_log]
  }

  @doc """
  Returns all permissions granted to `role`, including inherited ones.
  """
  @spec permissions_for(role()) :: MapSet.t()
  def permissions_for(role) when is_atom(role) do
    collect_permissions(role, MapSet.new(), MapSet.new())
  end

  @doc """
  Returns `true` if any of `subject`'s roles grant `permission`.
  """
  @spec has_permission?(subject(), permission()) :: boolean()
  def has_permission?(%{roles: roles}, permission) when is_atom(permission) do
    Enum.any?(roles, fn role ->
      permission in permissions_for(role)
    end)
  end

  @doc """
  Returns the effective set of all permissions for a subject across all their roles.
  """
  @spec effective_permissions(subject()) :: MapSet.t()
  def effective_permissions(%{roles: roles}) do
    Enum.reduce(roles, MapSet.new(), fn role, acc ->
      MapSet.union(acc, permissions_for(role))
    end)
  end

  @doc """
  Returns `true` if `role` is an ancestor (parent, grandparent, etc.) of `other_role`.
  """
  @spec inherits_from?(role(), role()) :: boolean()
  def inherits_from?(role, other_role) when is_atom(role) and is_atom(other_role) do
    other_role in ancestors(role)
  end

  @doc "Returns all ancestor roles for `role` in breadth-first order."
  @spec ancestors(role()) :: [role()]
  def ancestors(role) when is_atom(role) do
    collect_ancestors(role, [], MapSet.new())
  end

  @doc "Returns all roles that directly or indirectly inherit from `role`."
  @spec descendants(role()) :: [role()]
  def descendants(role) when is_atom(role) do
    @role_hierarchy
    |> Map.keys()
    |> Enum.filter(fn r -> role in ancestors(r) end)
  end

  defp collect_permissions(role, acc_perms, visited) do
    if MapSet.member?(visited, role) do
      acc_perms
    else
      direct = MapSet.new(Map.get(@role_permissions, role, []))
      parents = Map.get(@role_hierarchy, role, [])
      new_visited = MapSet.put(visited, role)
      with_direct = MapSet.union(acc_perms, direct)

      Enum.reduce(parents, with_direct, fn parent, perms ->
        collect_permissions(parent, perms, new_visited)
      end)
    end
  end

  defp collect_ancestors(role, acc, visited) do
    if MapSet.member?(visited, role) do
      acc
    else
      parents = Map.get(@role_hierarchy, role, [])
      new_visited = MapSet.put(visited, role)

      Enum.reduce(parents, acc ++ parents, fn parent, current_acc ->
        collect_ancestors(parent, current_acc, new_visited)
      end)
    end
  end
end
```
