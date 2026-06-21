# File: `example_good_243.md`

```elixir
defmodule Accounts.RoleManager do
  @moduledoc """
  Manages role assignments and permission checks for the application's
  role-based access control (RBAC) system.

  Roles are scoped to a resource type and optional resource ID, enabling
  both global roles (e.g. `:admin`) and resource-specific roles
  (e.g. `:editor` on a particular project).
  """

  import Ecto.Query, warn: false

  alias Accounts.{Repo, RoleAssignment, User}

  @type user_id :: Ecto.UUID.t()
  @type role :: atom()
  @type resource_type :: String.t()
  @type resource_id :: String.t() | nil

  @type permission :: atom()

  @role_permissions %{
    admin: [:read, :write, :delete, :manage_members, :manage_roles],
    editor: [:read, :write],
    viewer: [:read],
    moderator: [:read, :write, :delete]
  }

  @doc """
  Assigns `role` to `user` scoped to an optional resource.

  When `resource_id` is `nil`, the role is global within the resource type.
  Returns `{:ok, assignment}` or `{:error, :already_assigned}`.
  """
  @spec assign(User.t(), role(), resource_type(), resource_id()) ::
          {:ok, RoleAssignment.t()} | {:error, :already_assigned | Ecto.Changeset.t()}
  def assign(%User{} = user, role, resource_type, resource_id \\ nil)
      when is_atom(role) and is_binary(resource_type) do
    if assigned?(user, role, resource_type, resource_id) do
      {:error, :already_assigned}
    else
      create_assignment(user, role, resource_type, resource_id)
    end
  end

  @doc """
  Removes a role assignment from a user.

  Returns `:ok` even if the assignment did not exist.
  """
  @spec revoke(User.t(), role(), resource_type(), resource_id()) :: :ok
  def revoke(%User{id: user_id}, role, resource_type, resource_id \\ nil)
      when is_atom(role) and is_binary(resource_type) do
    RoleAssignment
    |> where([r], r.user_id == ^user_id and r.role == ^role and
               r.resource_type == ^resource_type)
    |> filter_resource_id(resource_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Returns `true` when `user` has `permission` on the given resource.

  Checks both resource-scoped and global assignments. Users with the
  `:admin` role on any scope are granted all permissions.
  """
  @spec permitted?(User.t(), permission(), resource_type(), resource_id()) :: boolean()
  def permitted?(%User{} = user, permission, resource_type, resource_id \\ nil) do
    user_roles = list_roles(user, resource_type, resource_id)

    Enum.any?(user_roles, fn role ->
      permission in Map.get(@role_permissions, role, [])
    end)
  end

  @doc """
  Returns all roles assigned to a user for a given resource type,
  including global assignments.
  """
  @spec list_roles(User.t(), resource_type(), resource_id()) :: [role()]
  def list_roles(%User{id: user_id}, resource_type, resource_id \\ nil) do
    global_roles =
      RoleAssignment
      |> where([r], r.user_id == ^user_id and r.resource_type == ^resource_type and is_nil(r.resource_id))
      |> select([r], r.role)
      |> Repo.all()

    scoped_roles =
      if resource_id do
        RoleAssignment
        |> where([r], r.user_id == ^user_id and r.resource_type == ^resource_type and r.resource_id == ^resource_id)
        |> select([r], r.role)
        |> Repo.all()
      else
        []
      end

    (global_roles ++ scoped_roles) |> Enum.uniq()
  end

  @doc """
  Returns all users that hold `role` on the given resource.
  """
  @spec list_users_with_role(role(), resource_type(), resource_id()) :: [User.t()]
  def list_users_with_role(role, resource_type, resource_id \\ nil)
      when is_atom(role) and is_binary(resource_type) do
    RoleAssignment
    |> where([r], r.role == ^role and r.resource_type == ^resource_type)
    |> filter_resource_id(resource_id)
    |> join(:inner, [r], u in User, on: u.id == r.user_id)
    |> select([_r, u], u)
    |> Repo.all()
  end

  defp assigned?(%User{id: user_id}, role, resource_type, resource_id) do
    RoleAssignment
    |> where([r], r.user_id == ^user_id and r.role == ^role and r.resource_type == ^resource_type)
    |> filter_resource_id(resource_id)
    |> Repo.exists?()
  end

  defp create_assignment(user, role, resource_type, resource_id) do
    %{user_id: user.id, role: role, resource_type: resource_type, resource_id: resource_id}
    |> RoleAssignment.changeset()
    |> Repo.insert()
  end

  defp filter_resource_id(query, nil), do: where(query, [r], is_nil(r.resource_id))
  defp filter_resource_id(query, id), do: where(query, [r], r.resource_id == ^id)
end
```
