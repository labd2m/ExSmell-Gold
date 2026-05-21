## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `flatten_permission_list/1` — the `Enum.flat_map(roles, ...)` call
- **Affected function(s):** `UserManagement.RoleService.flatten_permission_list/1`
- **Short explanation:** `Enum.flat_map/2` dispatches through the `Enumerable` protocol on `roles`. No guard clause restricts `roles` to types that implement `Enumerable`. Passing an integer, atom, float, binary, or PID raises `Protocol.UndefinedError`. Even passing a single `Role` struct (instead of a list of them) would crash the function unexpectedly.

```elixir
defmodule UserManagement.RoleService do
  @moduledoc """
  Manages role assignment, permission resolution, and access-control checks
  for the user management subsystem.
  """

  alias UserManagement.{Role, User, Permission, AuditLog}

  @super_admin_role "super_admin"
  @permission_cache_ttl_seconds 300

  def assign_role(%User{} = user, role_name) when is_binary(role_name) do
    with {:ok, role} <- Role.fetch_by_name(role_name),
         :ok <- check_assignment_allowed(user, role),
         {:ok, updated_user} <- User.add_role(user, role) do
      AuditLog.record(:role_assigned, %{user_id: user.id, role: role_name})
      invalidate_permission_cache(user.id)
      {:ok, updated_user}
    end
  end

  def revoke_role(%User{} = user, role_name) when is_binary(role_name) do
    with {:ok, role} <- Role.fetch_by_name(role_name),
         {:ok, updated_user} <- User.remove_role(user, role) do
      AuditLog.record(:role_revoked, %{user_id: user.id, role: role_name})
      invalidate_permission_cache(user.id)
      {:ok, updated_user}
    end
  end

  def has_permission?(%User{id: user_id} = user, permission_code) do
    permissions =
      case fetch_cached_permissions(user_id) do
        {:hit, perms} -> perms
        :miss -> compute_and_cache_permissions(user)
      end

    permission_code in permissions
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because `Enum.flat_map/2` dispatches through the
  # VALIDATION: `Enumerable` protocol on `roles`. No guard clause restricts `roles` to
  # VALIDATION: types that implement `Enumerable` (e.g., list, map, range, MapSet).
  # VALIDATION: Passing a single `Role` struct, an integer, an atom, or any non-Enumerable
  # VALIDATION: value raises `Protocol.UndefinedError` at runtime. The function silently
  # VALIDATION: accepts any value as input, making the contract invisible to callers.
  def flatten_permission_list(roles) do
    roles
    |> Enum.flat_map(fn %Role{permissions: perms} -> perms end)
    |> Enum.map(& &1.code)
    |> Enum.uniq()
  end
  # VALIDATION: SMELL END

  def effective_permissions(%User{roles: roles}) do
    {:ok, flatten_permission_list(roles)}
  end

  def roles_with_permission(permission_code) when is_binary(permission_code) do
    case Role.list_all() do
      {:ok, roles} ->
        matching =
          Enum.filter(roles, fn role ->
            Enum.any?(role.permissions, &(&1.code == permission_code))
          end)

        {:ok, matching}

      {:error, _} = err ->
        err
    end
  end

  def super_admin?(%User{roles: roles}) do
    Enum.any?(roles, &(&1.name == @super_admin_role))
  end

  def permission_diff(%User{} = user_a, %User{} = user_b) do
    perms_a = user_a.roles |> flatten_permission_list() |> MapSet.new()
    perms_b = user_b.roles |> flatten_permission_list() |> MapSet.new()

    %{
      only_in_a: MapSet.difference(perms_a, perms_b) |> MapSet.to_list(),
      only_in_b: MapSet.difference(perms_b, perms_a) |> MapSet.to_list(),
      shared: MapSet.intersection(perms_a, perms_b) |> MapSet.to_list()
    }
  end

  defp compute_and_cache_permissions(%User{roles: roles, id: id}) do
    perms = flatten_permission_list(roles)
    cache_permissions(id, perms)
    perms
  end

  defp check_assignment_allowed(_user, %Role{name: @super_admin_role}) do
    {:error, :super_admin_requires_elevated_approval}
  end

  defp check_assignment_allowed(_user, _role), do: :ok

  defp fetch_cached_permissions(_user_id), do: :miss
  defp cache_permissions(_user_id, _perms), do: :ok
  defp invalidate_permission_cache(_user_id), do: :ok
end
```
