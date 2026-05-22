```elixir
defmodule AccessControl do
  @moduledoc """
  Provides fine-grained permission checks for resources across the platform.
  Supports role-based and ownership-based access control.
  """

  alias AccessControl.{Permission, Policy, Role, User}
  require Logger

  @superadmin_role :superadmin
  @owner_placeholder :__owner__

  @doc """
  Loads the active policy for a named resource type from the policy registry.
  """
  def load_policy(resource_type) when is_atom(resource_type) do
    Policy.fetch(resource_type)
  end

  @doc """
  Returns all permissions granted to a role for a given resource type.
  """
  def permissions_for_role(role, resource_type) when is_atom(role) and is_atom(resource_type) do
    with {:ok, policy} <- load_policy(resource_type) do
      granted = Map.get(policy.role_permissions, role, [])
      {:ok, granted}
    end
  end
  
  # Checks whether a user is authorised to perform an action on a resource.
  #
  # Parameters:
  #   user     - %User{} struct with :id, :roles, and :owned_resource_ids fields
  #   action   - atom representing the operation, e.g. :read, :write, :delete
  #   resource - map or struct with a :type field (atom) and an :owner_id field (binary | nil)
  #
  # Logic:
  #   1. Superadmins bypass all checks and are always authorised.
  #   2. If the policy grants the :__owner__ placeholder for the action, ownership of the
  #      resource by the user also grants access.
  #   3. Otherwise, the user must have at least one role that grants the action.
  #
  # Returns :ok if authorised, {:error, :forbidden} otherwise.
  def authorize(%User{roles: roles} = user, action, %{type: resource_type} = resource)
      when is_atom(action) do
    if @superadmin_role in roles do
      :ok
    else
      with {:ok, policy} <- load_policy(resource_type) do
        allowed_roles = Map.get(policy.role_permissions, action, [])

        owner_allowed = @owner_placeholder in allowed_roles
        user_is_owner = resource[:owner_id] == user.id

        role_match = Enum.any?(roles, &(&1 in allowed_roles))

        if role_match or (owner_allowed and user_is_owner) do
          :ok
        else
          Logger.warning("Access denied: user=#{user.id} action=#{action} resource=#{resource_type}")
          {:error, :forbidden}
        end
      end
    end
  end

  @doc """
  Convenience function that raises `AccessControl.ForbiddenError` instead of
  returning `{:error, :forbidden}`.
  """
  def authorize!(user, action, resource) do
    case authorize(user, action, resource) do
      :ok -> :ok
      {:error, :forbidden} -> raise AccessControl.ForbiddenError, action: action, resource: resource
    end
  end

  @doc """
  Checks whether a given role exists in the system's role registry.
  """
  def valid_role?(role) when is_atom(role) do
    role in Role.all()
  end

  @doc """
  Returns all actions a user may perform on a specific resource, based on
  their current role set.
  """
  def permitted_actions(%User{roles: roles}, resource_type) when is_atom(resource_type) do
    with {:ok, policy} <- load_policy(resource_type) do
      actions =
        policy.role_permissions
        |> Enum.filter(fn {_action, allowed_roles} ->
          Enum.any?(roles, &(&1 in allowed_roles))
        end)
        |> Enum.map(fn {action, _} -> action end)

      {:ok, actions}
    end
  end
end
```
