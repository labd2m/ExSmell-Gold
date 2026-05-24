# Annotated Example — Code Smell

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `UserManagement.TeamManager.add_member/3`
- **Affected function(s):** `add_member/3`, `check_seat_availability/2`
- **Short explanation:** `TeamManager` directly reads internal fields of `Organization` (`org.plan_tier`, `org.seat_limit`, `org.current_seat_count`, `org.sso_enforced`, `org.allowed_domains`) and `Member` (`member.status`, `member.role`, `member.identity_provider`) to enforce membership rules. These checks belong inside `Organization` and `Member` modules, not scattered across `TeamManager`.

```elixir
defmodule UserManagement.TeamManager do
  @moduledoc """
  Manages team membership within organizations, including invitations,
  role assignments, seat-limit enforcement, and SSO compliance checks.
  """

  require Logger

  alias UserManagement.{Organization, Member, Invitation, AuditEvent}
  alias Accounts.User
  alias Notifications.Mailer
  alias Repo

  @role_hierarchy [:viewer, :editor, :admin, :owner]
  @owner_protected_roles [:owner]

  def add_member(org_id, invitee_email, role) do
    with {:ok, org} <- Organization.fetch(org_id),
         {:ok, inviter} <- User.fetch_current(),
         {:ok, inviter_member} <- Member.fetch(inviter.id, org_id) do
      validate_and_invite(org, invitee_email, role, inviter_member)
    end
  end

  # VALIDATION: SMELL START - Inappropriate Intimacy
  # VALIDATION: This is a smell because validate_and_invite/4 and check_seat_availability/2
  # VALIDATION: directly access internal fields of Organization (plan_tier, seat_limit,
  # VALIDATION: current_seat_count, sso_enforced, allowed_domains) and Member (role, status,
  # VALIDATION: identity_provider) to enforce rules that should be encapsulated in those modules.
  defp validate_and_invite(org, invitee_email, role, inviter_member) do
    cond do
      inviter_member.status != :active ->
        {:error, :inviter_not_active}

      not can_assign_role?(inviter_member.role, role) ->
        {:error, :insufficient_permissions}

      org.sso_enforced and not email_in_allowed_domain?(invitee_email, org.allowed_domains) ->
        {:error, :sso_domain_mismatch}

      true ->
        case check_seat_availability(org) do
          :ok -> create_invitation(org, invitee_email, role, inviter_member)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp check_seat_availability(org) do
    cond do
      org.plan_tier == :enterprise ->
        :ok

      org.seat_limit == nil ->
        :ok

      org.current_seat_count >= org.seat_limit ->
        {:error, :seat_limit_reached}

      true ->
        :ok
    end
  end
  # VALIDATION: SMELL END

  defp can_assign_role?(inviter_role, target_role) do
    inviter_idx = Enum.find_index(@role_hierarchy, &(&1 == inviter_role))
    target_idx = Enum.find_index(@role_hierarchy, &(&1 == target_role))

    cond do
      is_nil(inviter_idx) or is_nil(target_idx) -> false
      target_role in @owner_protected_roles -> false
      inviter_idx > target_idx -> true
      inviter_role == :owner -> true
      true -> false
    end
  end

  defp email_in_allowed_domain?(email, allowed_domains) do
    domain = email |> String.split("@") |> List.last()
    domain in allowed_domains
  end

  defp create_invitation(org, invitee_email, role, inviter_member) do
    invitation = %Invitation{
      org_id: org.id,
      email: invitee_email,
      role: role,
      invited_by: inviter_member.user_id,
      token: generate_token(),
      expires_at: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second),
      status: :pending
    }

    case Repo.insert(invitation) do
      {:ok, saved} ->
        Mailer.send_invitation(invitee_email, org.name, saved.token)
        record_audit(org.id, inviter_member.user_id, :member_invited, %{email: invitee_email})
        Logger.info("Invitation #{saved.id} sent to #{invitee_email} for org #{org.id}")
        {:ok, saved}

      {:error, changeset} ->
        Logger.error("Failed to create invitation: #{inspect(changeset.errors)}")
        {:error, :invitation_failed}
    end
  end

  def remove_member(org_id, member_user_id) do
    with {:ok, member} <- Member.fetch(member_user_id, org_id) do
      if member.role == :owner do
        {:error, :cannot_remove_owner}
      else
        member
        |> Member.changeset(%{status: :removed, removed_at: DateTime.utc_now()})
        |> Repo.update()
      end
    end
  end

  defp record_audit(org_id, actor_id, event, metadata) do
    %AuditEvent{org_id: org_id, actor_id: actor_id, event: event, metadata: metadata}
    |> Repo.insert()
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
