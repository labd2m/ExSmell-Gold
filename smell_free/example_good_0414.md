```elixir
defmodule IAM.RoleHierarchy do
  @moduledoc """
  Models a role hierarchy as a directed acyclic graph. Child roles
  inherit all permissions of their parent roles. Effective permissions
  for any role are computed by traversing the hierarchy upward and
  unioning all granted permission sets. The hierarchy is defined at
  compile time via application configuration and cached in a module
  attribute for zero-cost reads.
  """

  @type role :: atom()
  @type permission :: atom()
  @type hierarchy :: %{role() => [role()]}

  @hierarchy Application.compile_env(:my_app, :role_hierarchy, %{
    admin: [:editor],
    editor: [:viewer],
    viewer: [],
    billing_admin: [:viewer],
    support: [:viewer]
  })

  @permissions Application.compile_env(:my_app, :role_permissions, %{
    admin: [:delete_user, :manage_billing, :view_reports],
    editor: [:create_content, :edit_content, :publish_content],
    viewer: [:view_content, :view_profile],
    billing_admin: [:manage_billing, :view_invoices],
    support: [:view_tickets, :reply_tickets]
  })

  @doc "Returns the effective permission set for `role`, including inherited permissions."
  @spec effective_permissions(role()) :: MapSet.t()
  def effective_permissions(role) when is_atom(role) do
    collect_permissions(role, MapSet.new(), MapSet.new())
  end

  @doc "Returns true when `role` has the given `permission`, directly or through inheritance."
  @spec has_permission?(role(), permission()) :: boolean()
  def has_permission?(role, permission) when is_atom(role) and is_atom(permission) do
    MapSet.member?(effective_permissions(role), permission)
  end

  @doc "Returns all roles that inherit from `role` directly or transitively."
  @spec descendants(role()) :: [role()]
  def descendants(role) when is_atom(role) do
    @hierarchy
    |> Map.keys()
    |> Enum.filter(fn r -> r != role and inherits?(r, role) end)
  end

  @doc "Returns true when `child_role` inherits from `ancestor_role`."
  @spec inherits?(role(), role()) :: boolean()
  def inherits?(child_role, ancestor_role)
      when is_atom(child_role) and is_atom(ancestor_role) do
    MapSet.member?(ancestor_set(child_role, MapSet.new()), ancestor_role)
  end

  defp collect_permissions(role, visited, acc) do
    if MapSet.member?(visited, role) do
      acc
    else
      direct = @permissions |> Map.get(role, []) |> MapSet.new()
      parents = Map.get(@hierarchy, role, [])
      new_visited = MapSet.put(visited, role)

      Enum.reduce(parents, MapSet.union(acc, direct), fn parent, perm_acc ->
        collect_permissions(parent, new_visited, perm_acc)
      end)
    end
  end

  defp ancestor_set(role, visited) do
    parents = Map.get(@hierarchy, role, [])

    Enum.reduce(parents, MapSet.union(visited, MapSet.new(parents)), fn parent, acc ->
      if MapSet.member?(acc, parent) do
        acc
      else
        ancestor_set(parent, acc)
      end
    end)
  end
end
```
