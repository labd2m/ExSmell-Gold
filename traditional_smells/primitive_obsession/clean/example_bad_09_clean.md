```elixir
defmodule Auth.PermissionGuard do
  @moduledoc """
  Evaluates whether an authenticated principal holds the permissions
  required to perform an action. Supports resource-scoped permissions
  in the format `<resource>:<action>` and a wildcard `*` for full
  access grants.
  """

  require Logger

  @valid_resources ~w(orders invoices shipments users products reports admin)
  @valid_actions ~w(read write delete manage)

  @spec authorize(list(String.t()), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def authorize(permissions, resource, action)
      when is_list(permissions) and is_binary(resource) and is_binary(action) do
    if has_permission?(permissions, resource, action) do
      Logger.debug("Access granted: #{resource}:#{action}")
      :ok
    else
      Logger.warning("Access denied: #{resource}:#{action} not in #{inspect(permissions)}")
      {:error, "Permission denied: #{resource}:#{action}"}
    end
  end

  @spec grant_permission(list(String.t()), String.t()) ::
          {:ok, list(String.t())} | {:error, String.t()}
  def grant_permission(permissions, new_permission) do
    with :ok <- validate_permission_string(new_permission) do
      if new_permission in permissions do
        {:ok, permissions}
      else
        {:ok, [new_permission | permissions]}
      end
    end
  end

  @spec revoke_permission(list(String.t()), String.t()) :: {:ok, list(String.t())}
  def revoke_permission(permissions, permission_to_remove) do
    updated = Enum.reject(permissions, &(&1 == permission_to_remove))
    {:ok, updated}
  end

  @spec has_all_permissions?(list(String.t()), list(String.t())) :: boolean()
  def has_all_permissions?(permissions, required) do
    Enum.all?(required, fn req ->
      [resource, action] = String.split(req, ":", parts: 2)
      has_permission?(permissions, resource, action)
    end)
  end

  @spec merge_permissions(list(String.t()), list(String.t())) :: list(String.t())
  def merge_permissions(permissions_a, permissions_b) do
    (permissions_a ++ permissions_b)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec list_granted_resources(list(String.t())) :: list(String.t())
  def list_granted_resources(permissions) do
    permissions
    |> Enum.flat_map(fn
      "*" -> @valid_resources
      perm -> [hd(String.split(perm, ":", parts: 2))]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp has_permission?(permissions, resource, action) do
    Enum.any?(permissions, fn
      "*" ->
        true

      perm ->
        case String.split(perm, ":", parts: 2) do
          [^resource, "manage"] -> true
          [^resource, ^action] -> true
          _ -> false
        end
    end)
  end

  defp validate_permission_string("*"), do: :ok

  defp validate_permission_string(permission) do
    case String.split(permission, ":", parts: 2) do
      [resource, action] ->
        with :ok <- validate_resource(resource),
             :ok <- validate_action(action) do
          :ok
        end

      _ ->
        {:error,
         "Invalid permission format '#{permission}'. Expected '<resource>:<action>' or '*'"}
    end
  end

  defp validate_resource(resource) do
    if resource in @valid_resources do
      :ok
    else
      {:error, "Unknown resource '#{resource}'. Valid: #{Enum.join(@valid_resources, ", ")}"}
    end
  end

  defp validate_action(action) do
    if action in @valid_actions do
      :ok
    else
      {:error, "Unknown action '#{action}'. Valid: #{Enum.join(@valid_actions, ", ")}"}
    end
  end
end
```
