# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `to_permission_atom/1` function
- **Affected function(s):** `to_permission_atom/1`, `load_permissions/1`
- **Short explanation:** The function converts permission scope strings loaded from a database-backed role configuration into atoms via `String.to_atom/1`. Because role permissions are stored as free-form strings in the database and can be extended by administrators, this dynamically creates atoms from data that is not bounded at compile time.

---

```elixir
defmodule Auth.PermissionLoader do
  @moduledoc """
  Loads role-based permissions from the access control database and caches
  them in an ETS table for fast in-process lookups during request handling.
  """

  require Logger

  alias Auth.{RoleRepo, PermissionCache}

  @cache_ttl_seconds 300

  @spec load_all() :: {:ok, non_neg_integer()} | {:error, term()}
  def load_all do
    Logger.info("Loading all role permissions into cache")

    case RoleRepo.list_roles_with_permissions() do
      {:ok, roles} ->
        loaded =
          roles
          |> Enum.map(&load_permissions/1)
          |> Enum.count(fn
            {:ok, _} -> true
            _ -> false
          end)

        Logger.info("Permission cache populated", roles_loaded: loaded)
        {:ok, loaded}

      {:error, reason} ->
        Logger.error("Failed to load permissions", reason: inspect(reason))
        {:error, reason}
    end
  end

  @spec check(String.t(), String.t()) :: boolean()
  def check(role_id, permission) when is_binary(role_id) and is_binary(permission) do
    case PermissionCache.get(role_id) do
      {:hit, perms} -> permission in perms
      :miss ->
        Logger.warning("Permission cache miss", role_id: role_id)
        false
    end
  end

  defp load_permissions(%{id: role_id, permissions: raw_permissions} = role) do
    Logger.debug("Loading permissions for role", role: role.name, role_id: role_id)

    parsed =
      raw_permissions
      |> Enum.map(&parse_permission_entry/1)
      |> Enum.reject(&is_nil/1)

    case PermissionCache.put(role_id, parsed, ttl: @cache_ttl_seconds) do
      :ok ->
        {:ok, %{role_id: role_id, permission_count: length(parsed)}}

      {:error, reason} ->
        Logger.error("Failed to cache permissions",
          role_id: role_id,
          reason: inspect(reason)
        )
        {:error, reason}
    end
  end

  defp parse_permission_entry(%{scope: scope, resource: resource, action: action}) do
    # VALIDATION: SMELL START - Dynamic atom creation
    # VALIDATION: This is a smell because `to_permission_atom/1` calls
    # `String.to_atom/1` on permission scope strings loaded from the database.
    # Administrators can insert arbitrary scope strings through an admin UI,
    # meaning the set of atoms grows as roles are added or modified. The
    # developer cannot statically bound the number of atoms that will be
    # created.
    scope_atom = to_permission_atom(scope)
    # VALIDATION: SMELL END

    if scope_atom do
      %{scope: scope_atom, resource: resource, action: action}
    else
      Logger.warning("Unknown permission scope, skipping", scope: scope)
      nil
    end
  end

  defp parse_permission_entry(entry) do
    Logger.warning("Malformed permission entry", entry: inspect(entry))
    nil
  end

  defp to_permission_atom(scope) when is_binary(scope) do
    scope
    |> String.trim()
    |> String.downcase()
    |> String.to_atom()
  end

  defp to_permission_atom(_), do: nil

  @spec reload_role(String.t()) :: :ok | {:error, term()}
  def reload_role(role_id) when is_binary(role_id) do
    Logger.info("Reloading permissions for role", role_id: role_id)

    case RoleRepo.get_role_with_permissions(role_id) do
      {:ok, role} ->
        case load_permissions(role) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      {:error, :not_found} ->
        PermissionCache.delete(role_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(role_id) do
    PermissionCache.delete(role_id)
    :ok
  end
end
```
