```elixir
defmodule MyApp.Accounts.OrganisationMembership do
  @moduledoc """
  Manages the relationship between users and organisations: adding
  members with a specified role, changing roles, removing members, and
  querying membership. All role changes are validated against a permission
  matrix ensuring that no member can grant a role higher than their own.

  Every mutation is recorded via the audit logger before the database
  write, providing a complete history even if the write subsequently fails.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Accounts.{User, OrgMember}
  alias MyApp.Compliance.AuditLogger

  @role_hierarchy [:viewer, :member, :manager, :admin, :owner]

  @type role :: :viewer | :member | :manager | :admin | :owner
  @type org_id :: String.t()
  @type user_id :: String.t()

  @doc """
  Adds `target_user_id` to `org_id` with `role`, checked against
  `actor`'s own role. Returns `{:error, :insufficient_permissions}` when
  the actor cannot grant the requested role.
  """
  @spec add_member(User.t(), org_id(), user_id(), role()) ::
          {:ok, OrgMember.t()}
          | {:error, :insufficient_permissions}
          | {:error, :already_member}
          | {:error, Ecto.Changeset.t()}
  def add_member(%User{} = actor, org_id, target_user_id, role)
      when is_binary(org_id) and is_binary(target_user_id) do
    with :ok <- check_can_grant(actor, org_id, role),
         :ok <- check_not_already_member(org_id, target_user_id) do
      AuditLogger.log(
        %{id: actor.id, type: :user},
        "org_membership.add",
        %{id: org_id, type: "organisation"},
        %{target_user_id: target_user_id, role: role}
      )

      %OrgMember{}
      |> OrgMember.changeset(%{org_id: org_id, user_id: target_user_id, role: role})
      |> Repo.insert()
    end
  end

  @doc """
  Updates the role of an existing member. Subject to the same permission
  check as `add_member/4`.
  """
  @spec change_role(User.t(), org_id(), user_id(), role()) ::
          {:ok, OrgMember.t()}
          | {:error, :insufficient_permissions}
          | {:error, :not_a_member}
          | {:error, Ecto.Changeset.t()}
  def change_role(%User{} = actor, org_id, target_user_id, new_role)
      when is_binary(org_id) and is_binary(target_user_id) do
    with :ok <- check_can_grant(actor, org_id, new_role),
         {:ok, member} <- fetch_member(org_id, target_user_id) do
      AuditLogger.log(
        %{id: actor.id, type: :user},
        "org_membership.role_changed",
        %{id: org_id, type: "organisation"},
        %{target_user_id: target_user_id, old_role: member.role, new_role: new_role}
      )

      member |> OrgMember.changeset(%{role: new_role}) |> Repo.update()
    end
  end

  @doc "Removes `target_user_id` from `org_id`."
  @spec remove_member(User.t(), org_id(), user_id()) ::
          :ok | {:error, :insufficient_permissions} | {:error, :not_a_member}
  def remove_member(%User{} = actor, org_id, target_user_id)
      when is_binary(org_id) and is_binary(target_user_id) do
    with :ok <- check_can_remove(actor, org_id, target_user_id),
         {:ok, member} <- fetch_member(org_id, target_user_id) do
      Repo.delete(member)
      :ok
    end
  end

  @doc "Returns all members of `org_id` with their roles."
  @spec list_members(org_id()) :: [%{user: User.t(), role: role()}]
  def list_members(org_id) when is_binary(org_id) do
    OrgMember
    |> where([m], m.org_id == ^org_id)
    |> join(:inner, [m], u in User, on: u.id == m.user_id)
    |> select([m, u], %{user: u, role: m.role})
    |> order_by([m, _u], asc: m.inserted_at)
    |> Repo.all()
  end

  @spec check_can_grant(User.t(), org_id(), role()) ::
          :ok | {:error, :insufficient_permissions}
  defp check_can_grant(actor, org_id, target_role) do
    case actor_role(actor, org_id) do
      nil -> {:error, :insufficient_permissions}
      actor_role ->
        if role_rank(actor_role) > role_rank(target_role), do: :ok,
          else: {:error, :insufficient_permissions}
    end
  end

  @spec check_can_remove(User.t(), org_id(), user_id()) ::
          :ok | {:error, :insufficient_permissions}
  defp check_can_remove(actor, org_id, target_user_id) do
    case {actor_role(actor, org_id), fetch_member(org_id, target_user_id)} do
      {nil, _} -> {:error, :insufficient_permissions}
      {_, {:error, _}} -> {:error, :not_a_member}
      {a_role, {:ok, member}} ->
        if role_rank(a_role) > role_rank(member.role), do: :ok,
          else: {:error, :insufficient_permissions}
    end
  end

  @spec check_not_already_member(org_id(), user_id()) ::
          :ok | {:error, :already_member}
  defp check_not_already_member(org_id, user_id) do
    if Repo.get_by(OrgMember, org_id: org_id, user_id: user_id),
      do: {:error, :already_member},
      else: :ok
  end

  @spec fetch_member(org_id(), user_id()) :: {:ok, OrgMember.t()} | {:error, :not_a_member}
  defp fetch_member(org_id, user_id) do
    case Repo.get_by(OrgMember, org_id: org_id, user_id: user_id) do
      nil -> {:error, :not_a_member}
      m -> {:ok, m}
    end
  end

  @spec actor_role(User.t(), org_id()) :: role() | nil
  defp actor_role(actor, org_id) do
    case Repo.get_by(OrgMember, org_id: org_id, user_id: actor.id) do
      nil -> nil
      m -> m.role
    end
  end

  @spec role_rank(role()) :: non_neg_integer()
  defp role_rank(role), do: Enum.find_index(@role_hierarchy, &(&1 == role)) || 0
end
```
