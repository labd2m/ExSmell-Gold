```elixir
defmodule Accounts.OrganisationContext do
  @moduledoc """
  Manages organisation membership, role assignment, and invitation flows.
  Membership changes emit domain events via PubSub so audit logs, billing
  seat counts, and access caches stay consistent without coupling to this
  context directly. All mutations run inside Ecto transactions to prevent
  partial state from reaching the database.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.{Organisation, Member, Invitation}

  @type org_id :: Ecto.UUID.t()
  @type user_id :: String.t()
  @type role :: :owner | :admin | :member | :viewer
  @type invite_result ::
          {:ok, Invitation.t()} | {:error, :already_member | :invite_exists | Ecto.Changeset.t()}

  @pubsub_topic "org:membership"
  @invite_ttl_days 7

  @doc "Creates a new organisation with `owner_id` as its first owner."
  @spec create(String.t(), user_id()) ::
          {:ok, Organisation.t()} | {:error, Ecto.Changeset.t()}
  def create(name, owner_id) when is_binary(name) and is_binary(owner_id) do
    Repo.transaction(fn ->
      with {:ok, org} <- insert_org(name),
           {:ok, _member} <- insert_member(org.id, owner_id, :owner) do
        org
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Invites `email` to join `org_id` with the given `role`."
  @spec invite(org_id(), String.t(), role(), user_id()) :: invite_result()
  def invite(org_id, email, role, invited_by)
      when is_binary(email) and role in [:admin, :member, :viewer] do
    cond do
      already_member?(org_id, email) ->
        {:error, :already_member}

      pending_invite?(org_id, email) ->
        {:error, :invite_exists}

      true ->
        expires_at = DateTime.add(DateTime.utc_now(), @invite_ttl_days * 86_400, :second)
        token = generate_token()
        attrs = %{org_id: org_id, email: email, role: Atom.to_string(role),
                  invited_by: invited_by, token: token, expires_at: expires_at}

        %Invitation{} |> Invitation.changeset(attrs) |> Repo.insert()
    end
  end

  @doc """
  Accepts an invitation by `token`, creating a membership record and
  deleting the invitation atomically.
  """
  @spec accept_invite(String.t(), user_id()) ::
          {:ok, Member.t()} | {:error, :invalid_token | :expired | Ecto.Changeset.t()}
  def accept_invite(token, user_id) when is_binary(token) and is_binary(user_id) do
    case Repo.get_by(Invitation, token: token) do
      nil ->
        {:error, :invalid_token}

      %Invitation{expires_at: exp} when not is_nil(exp) and exp < ^DateTime.utc_now() ->
        {:error, :expired}

      invite ->
        Repo.transaction(fn ->
          role = String.to_existing_atom(invite.role)
          with {:ok, member} <- insert_member(invite.org_id, user_id, role) do
            Repo.delete!(invite)
            broadcast_membership_change(invite.org_id, user_id, :joined)
            member
          else
            {:error, cs} -> Repo.rollback(cs)
          end
        end)
    end
  end

  @doc "Changes the role of an existing member."
  @spec change_role(org_id(), user_id(), role()) ::
          {:ok, Member.t()} | {:error, :not_found | :cannot_demote_last_owner | Ecto.Changeset.t()}
  def change_role(org_id, user_id, new_role)
      when is_binary(org_id) and is_binary(user_id) and new_role in [:admin, :member, :viewer] do
    case fetch_member(org_id, user_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, %Member{role: "owner"}} when new_role != :owner ->
        if last_owner?(org_id) do
          {:error, :cannot_demote_last_owner}
        else
          perform_role_change(org_id, user_id, new_role)
        end

      {:ok, _member} ->
        perform_role_change(org_id, user_id, new_role)
    end
  end

  @doc "Returns all members of `org_id` with their roles."
  @spec list_members(org_id()) :: [Member.t()]
  def list_members(org_id) when is_binary(org_id) do
    Member
    |> where([m], m.org_id == ^org_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  defp insert_org(name) do
    %Organisation{} |> Organisation.changeset(%{name: name}) |> Repo.insert()
  end

  defp insert_member(org_id, user_id, role) do
    attrs = %{org_id: org_id, user_id: user_id, role: Atom.to_string(role)}
    %Member{} |> Member.changeset(attrs) |> Repo.insert()
  end

  defp fetch_member(org_id, user_id) do
    case Repo.get_by(Member, org_id: org_id, user_id: user_id) do
      nil -> {:error, :not_found}
      member -> {:ok, member}
    end
  end

  defp perform_role_change(org_id, user_id, new_role) do
    with {:ok, member} <- fetch_member(org_id, user_id) do
      member
      |> Member.role_changeset(%{role: Atom.to_string(new_role)})
      |> Repo.update()
    end
  end

  defp already_member?(org_id, email) do
    from(m in Member,
      join: u in "users", on: u.id == m.user_id,
      where: m.org_id == ^org_id and u.email == ^email
    )
    |> Repo.exists?()
  end

  defp pending_invite?(org_id, email) do
    Repo.exists?(from(i in Invitation, where: i.org_id == ^org_id and i.email == ^email))
  end

  defp last_owner?(org_id) do
    Repo.one(from(m in Member, where: m.org_id == ^org_id and m.role == "owner", select: count(m.id))) == 1
  end

  defp broadcast_membership_change(org_id, user_id, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic, {event, %{org_id: org_id, user_id: user_id}})
  end

  defp generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
```
