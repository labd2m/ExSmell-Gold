# File: `example_good_743.md`

```elixir
defmodule Accounts.TeamManager do
  @moduledoc """
  Manages team membership, roles, and invitations within an
  organisation. Teams have a configurable maximum size and enforce
  uniqueness of member roles where required by the domain.
  """

  import Ecto.Query, warn: false

  alias Accounts.{Repo, Team, TeamMember, User}

  @type team_id :: Ecto.UUID.t()
  @type user_id :: Ecto.UUID.t()
  @type role :: atom()

  @type member_result ::
          {:ok, TeamMember.t()}
          | {:error, :already_member | :team_full | Ecto.Changeset.t()}

  @doc """
  Adds `user` to `team` with the given `role`.

  Returns `{:error, :already_member}` when the user is already on the
  team, or `{:error, :team_full}` when the team has reached its limit.
  """
  @spec add_member(Team.t(), User.t(), role()) :: member_result()
  def add_member(%Team{} = team, %User{} = user, role) when is_atom(role) do
    with :ok <- check_not_member(team.id, user.id),
         :ok <- check_capacity(team) do
      insert_member(team, user, role)
    end
  end

  @doc """
  Removes `user` from `team`.

  Returns `:ok` even if the user was not a member.
  """
  @spec remove_member(team_id(), user_id()) :: :ok
  def remove_member(team_id, user_id)
      when is_binary(team_id) and is_binary(user_id) do
    TeamMember
    |> where([m], m.team_id == ^team_id and m.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Changes the role of an existing team member.

  Returns `{:ok, updated_member}` or `{:error, :not_member}`.
  """
  @spec change_role(team_id(), user_id(), role()) ::
          {:ok, TeamMember.t()} | {:error, :not_member | Ecto.Changeset.t()}
  def change_role(team_id, user_id, new_role)
      when is_binary(team_id) and is_binary(user_id) and is_atom(new_role) do
    case Repo.get_by(TeamMember, team_id: team_id, user_id: user_id) do
      nil ->
        {:error, :not_member}

      member ->
        member
        |> TeamMember.role_changeset(%{role: new_role})
        |> Repo.update()
    end
  end

  @doc """
  Returns all members of a team with their user records preloaded.
  """
  @spec list_members(team_id()) :: [TeamMember.t()]
  def list_members(team_id) when is_binary(team_id) do
    TeamMember
    |> where([m], m.team_id == ^team_id)
    |> preload(:user)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns all teams a user belongs to, with their team records preloaded.
  """
  @spec list_teams_for_user(user_id()) :: [TeamMember.t()]
  def list_teams_for_user(user_id) when is_binary(user_id) do
    TeamMember
    |> where([m], m.user_id == ^user_id)
    |> preload(:team)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns `true` when `user_id` is a member of `team_id`.
  """
  @spec member?(team_id(), user_id()) :: boolean()
  def member?(team_id, user_id)
      when is_binary(team_id) and is_binary(user_id) do
    TeamMember
    |> where([m], m.team_id == ^team_id and m.user_id == ^user_id)
    |> Repo.exists?()
  end

  @doc """
  Returns the count of members currently on a team.
  """
  @spec member_count(team_id()) :: non_neg_integer()
  def member_count(team_id) when is_binary(team_id) do
    TeamMember
    |> where([m], m.team_id == ^team_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Transfers ownership from the current owner to another existing member.

  Returns `{:error, :not_member}` if the target user is not on the team.
  """
  @spec transfer_ownership(Team.t(), user_id()) ::
          {:ok, Team.t()} | {:error, :not_member | Ecto.Changeset.t()}
  def transfer_ownership(%Team{} = team, new_owner_id) when is_binary(new_owner_id) do
    if member?(team.id, new_owner_id) do
      team
      |> Team.ownership_changeset(%{owner_id: new_owner_id})
      |> Repo.update()
    else
      {:error, :not_member}
    end
  end

  defp check_not_member(team_id, user_id) do
    if member?(team_id, user_id), do: {:error, :already_member}, else: :ok
  end

  defp check_capacity(%Team{max_members: nil}), do: :ok

  defp check_capacity(%Team{id: team_id, max_members: max}) do
    if member_count(team_id) >= max, do: {:error, :team_full}, else: :ok
  end

  defp insert_member(team, user, role) do
    %{team_id: team.id, user_id: user.id, role: role}
    |> TeamMember.changeset()
    |> Repo.insert()
  end
end
```
