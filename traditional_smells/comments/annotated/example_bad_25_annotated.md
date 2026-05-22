# Annotated Example — Code Smell: Comments

| Field | Value |
|---|---|
| **Smell name** | Comments |
| **Expected smell location** | `UserManager.deactivate_account/2` |
| **Affected function(s)** | `deactivate_account/2` |
| **Short explanation** | `deactivate_account/2` is described by inline `#` comments instead of an `@doc` attribute, bypassing all Elixir documentation tooling. |

```elixir
defmodule MyApp.UserManager do
  @moduledoc """
  Manages user lifecycle events including registration, profile updates,
  role assignments, and account deactivation for the MyApp platform.
  """

  alias MyApp.{Repo, User, Role, UserRole, AuditEvent, Session}
  alias MyApp.Mailer.AccountEmails
  require Logger

  @inactive_grace_period_days 30
  @default_roles [:viewer]

  @doc """
  Creates a new user account.

  Accepts a map of user attributes, assigns default roles, and sends a
  welcome email. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def register_user(attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <-
             %User{}
             |> User.registration_changeset(attrs)
             |> Repo.insert(),
           :ok <- assign_default_roles(user),
           :ok <- AccountEmails.send_welcome(user) do
        Logger.info("[UserManager] New user registered: #{user.id}")
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Updates a user's profile attributes.

  Only permits changes to safe fields (display name, avatar, locale).
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_profile(user_id, attrs) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      user ->
        user
        |> User.profile_changeset(attrs)
        |> Repo.update()
    end
  end

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `deactivate_account/2` uses `#` comment
  # VALIDATION: lines for documentation instead of the `@doc` attribute.
  # VALIDATION: Developers reading generated HTML docs or using IEx `h/1`
  # VALIDATION: will find no documentation for this function.

  # deactivate_account/2
  #
  # Soft-deletes a user account.
  #
  # Arguments:
  #   user_id    - integer ID of the user to deactivate
  #   performed_by - integer ID of the admin or the user themselves performing the action
  #
  # Steps:
  #   1. Marks the user record as :inactive and sets deactivated_at.
  #   2. Revokes all active sessions for the user.
  #   3. Records an audit event for compliance.
  #   4. Sends a goodbye email to the user.
  #
  # The record is retained for @inactive_grace_period_days days before
  # permanent deletion by the background cleanup job.
  #
  # Returns {:ok, user} or {:error, reason}.

  # VALIDATION: SMELL END
  def deactivate_account(user_id, performed_by) do
    Repo.transaction(fn ->
      case Repo.get(User, user_id) do
        nil ->
          Repo.rollback(:user_not_found)

        %User{status: :inactive} ->
          Repo.rollback(:already_inactive)

        user ->
          {:ok, updated_user} =
            user
            |> User.changeset(%{
              status: :inactive,
              deactivated_at: DateTime.utc_now(),
              scheduled_deletion_at:
                Date.add(Date.utc_today(), @inactive_grace_period_days)
            })
            |> Repo.update()

          revoke_all_sessions(user_id)

          AuditEvent.record(:account_deactivated, %{
            user_id: user_id,
            performed_by: performed_by,
            timestamp: DateTime.utc_now()
          })

          AccountEmails.send_deactivation_notice(user)

          Logger.info("[UserManager] Account #{user_id} deactivated by #{performed_by}")
          updated_user
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Assigns a named role to a user.

  Returns `{:ok, user_role}` or `{:error, :role_not_found}`.
  """
  def assign_role(user_id, role_name) do
    case Repo.get_by(Role, name: role_name) do
      nil ->
        {:error, :role_not_found}

      role ->
        %UserRole{}
        |> UserRole.changeset(%{user_id: user_id, role_id: role.id})
        |> Repo.insert(on_conflict: :nothing)
    end
  end

  @doc """
  Returns all roles assigned to a user as a list of role name strings.
  """
  def list_roles(user_id) do
    Repo.all(
      from(r in Role,
        join: ur in UserRole,
        on: ur.role_id == r.id,
        where: ur.user_id == ^user_id,
        select: r.name
      )
    )
  end

  ## Private

  defp assign_default_roles(user) do
    Enum.each(@default_roles, fn role_name ->
      assign_role(user.id, to_string(role_name))
    end)

    :ok
  end

  defp revoke_all_sessions(user_id) do
    Repo.update_all(
      from(s in Session, where: s.user_id == ^user_id and s.revoked == false),
      set: [revoked: true, revoked_at: DateTime.utc_now()]
    )
  end
end
```
