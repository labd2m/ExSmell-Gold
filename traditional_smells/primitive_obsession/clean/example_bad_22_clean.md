```elixir
defmodule Auth.AccessControl do
  @moduledoc """
  Role-based access control for the platform.
  Manages granting, revoking, and checking user permissions
  against protected resources.
  """

  require Logger

  alias Auth.Repo
  alias Auth.Schema.{User, UserPermission}


  @valid_roles ~w(admin manager viewer support)
  @valid_actions ~w(read write delete manage)

  @spec authorize(User.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized} | {:error, :invalid_permission}
  def authorize(%User{} = user, resource, action)
      when is_binary(resource) and is_binary(action) do
    permission_key = "#{action}:#{resource}"

    cond do
      user.role == "admin" ->
        :ok

      permission_key in user_permission_keys(user) ->
        :ok

      true ->
        Logger.warning("Unauthorized access: user=#{user.id} resource=#{resource} action=#{action}")
        {:error, :unauthorized}
    end
  end

  @spec grant_permission(User.t(), String.t(), String.t()) ::
          {:ok, UserPermission.t()} | {:error, term()}
  def grant_permission(%User{} = user, resource, action)
      when is_binary(resource) and is_binary(action) do
    with :ok <- validate_action(action),
         :ok <- validate_resource_format(resource),
         false <- already_granted?(user, resource, action) do
      attrs = %{
        user_id: user.id,
        resource: resource,
        action: action,
        granted_at: DateTime.utc_now()
      }

      %UserPermission{}
      |> UserPermission.changeset(attrs)
      |> Repo.insert()
    else
      true -> {:error, :already_granted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec revoke_permission(User.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke_permission(%User{} = user, resource, action)
      when is_binary(resource) and is_binary(action) do
    case Repo.get_by(UserPermission, user_id: user.id, resource: resource, action: action) do
      nil ->
        {:error, :not_found}

      permission ->
        case Repo.delete(permission) do
          {:ok, _} ->
            Logger.info("Permission revoked: user=#{user.id} #{action}:#{resource}")
            :ok

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @spec set_role(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def set_role(%User{} = user, role) when is_binary(role) do
    if role in @valid_roles do
      user
      |> User.changeset(%{role: role})
      |> Repo.update()
    else
      {:error, {:invalid_role, role}}
    end
  end

  @spec list_user_permissions(User.t()) :: list(map())
  def list_user_permissions(%User{} = user) do
    user
    |> Repo.preload(:permissions)
    |> Map.get(:permissions, [])
    |> Enum.map(fn perm ->
      %{
        resource: perm.resource,
        action: perm.action,
        key: "#{perm.action}:#{perm.resource}",
        granted_at: perm.granted_at
      }
    end)
  end


  ## Private helpers

  defp user_permission_keys(%User{} = user) do
    user
    |> Repo.preload(:permissions)
    |> Map.get(:permissions, [])
    |> Enum.map(&"#{&1.action}:#{&1.resource}")
  end

  defp validate_action(action) when action in @valid_actions, do: :ok
  defp validate_action(action), do: {:error, {:invalid_action, action}}

  defp validate_resource_format(resource) when is_binary(resource) do
    if String.match?(resource, ~r/^[a-z_]+$/) do
      :ok
    else
      {:error, {:invalid_resource_format, resource}}
    end
  end

  defp already_granted?(%User{} = user, resource, action) do
    Repo.exists?(UserPermission, user_id: user.id, resource: resource, action: action)
  end
end
```