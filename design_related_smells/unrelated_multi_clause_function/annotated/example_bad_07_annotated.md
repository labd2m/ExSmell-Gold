# Annotated Example 07

## Metadata

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `UserManager.perform/1`
- **Affected function(s):** `perform/1`
- **Short explanation:** The `perform/1` function mixes three distinct user management operations — creating a new user account, suspending an existing account for policy violations, and merging duplicate accounts — under one multi-clause function. These operations have entirely different preconditions, authorization requirements, and downstream effects.

---

```elixir
defmodule UserManager do
  @moduledoc """
  Handles lifecycle operations for user accounts in the platform.
  """

  alias UserManager.{
    CreateAccountCommand,
    SuspendAccountCommand,
    MergeAccountsCommand,
    Repo,
    Mailer,
    AuditLog,
    PasswordHasher
  }

  @default_roles [:viewer]
  @suspension_grace_period_days 30

  @doc """
  Performs a user account management operation.

  ## Examples

      iex> UserManager.perform(%CreateAccountCommand{email: "user@example.com", name: "Alice"})
      {:ok, %User{id: "usr_abc123", email: "user@example.com"}}

  """

  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because `perform/1` handles three operations that
  # belong to completely different user lifecycle stages: account creation (onboarding),
  # account suspension (moderation), and account merging (data consolidation).
  # Each clause requires different permissions, produces different audit events,
  # and has no shared logic with the others, yet they are all crammed into one
  # undocumentable multi-clause function.

  def perform(%CreateAccountCommand{
        email: email,
        name: name,
        password: password,
        invited_by: inviter_id
      }) do
    with {:ok, _} <- validate_email_uniqueness(email),
         hashed_pw <- PasswordHasher.hash(password),
         {:ok, user} <-
           Repo.create_user(%{
             email: String.downcase(email),
             name: name,
             password_hash: hashed_pw,
             roles: @default_roles,
             invited_by: inviter_id,
             status: :active,
             inserted_at: DateTime.utc_now()
           }) do
      Mailer.send_welcome_email(user)

      AuditLog.record(:account_created, %{
        user_id: user.id,
        invited_by: inviter_id,
        timestamp: DateTime.utc_now()
      })

      {:ok, user}
    end
  end

  # suspends a user account and notifies them of the reason
  def perform(%SuspendAccountCommand{
        user_id: user_id,
        reason: reason,
        suspended_by: admin_id
      })
      when is_binary(reason) and byte_size(reason) > 0 do
    with {:ok, user} <- Repo.find_user(user_id),
         :active <- user.status,
         {:ok, admin} <- Repo.find_user(admin_id),
         true <- :admin in admin.roles do
      reactivation_deadline = Date.add(Date.utc_today(), @suspension_grace_period_days)

      {:ok, suspended_user} =
        Repo.update_user(user_id, %{
          status: :suspended,
          suspension_reason: reason,
          suspended_at: DateTime.utc_now(),
          reactivation_deadline: reactivation_deadline
        })

      Mailer.send_suspension_notice(suspended_user, reason, reactivation_deadline)

      AuditLog.record(:account_suspended, %{
        user_id: user_id,
        reason: reason,
        suspended_by: admin_id,
        timestamp: DateTime.utc_now()
      })

      {:ok, suspended_user}
    else
      status when is_atom(status) -> {:error, :account_not_active}
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  # merges two duplicate user accounts, preserving the primary
  def perform(%MergeAccountsCommand{
        primary_user_id: primary_id,
        secondary_user_id: secondary_id,
        performed_by: admin_id
      })
      when primary_id != secondary_id do
    with {:ok, admin} <- Repo.find_user(admin_id),
         true <- :super_admin in admin.roles,
         {:ok, primary} <- Repo.find_user(primary_id),
         {:ok, _secondary} <- Repo.find_user(secondary_id),
         {:ok, _} <- Repo.transfer_resources(secondary_id, primary_id),
         {:ok, _} <- Repo.update_user(secondary_id, %{status: :merged, merged_into: primary_id}) do
      AuditLog.record(:accounts_merged, %{
        primary_id: primary_id,
        secondary_id: secondary_id,
        performed_by: admin_id,
        timestamp: DateTime.utc_now()
      })

      {:ok, primary}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL END

  defp validate_email_uniqueness(email) do
    case Repo.find_user_by_email(email) do
      {:ok, _} -> {:error, :email_already_taken}
      {:error, :not_found} -> {:ok, :available}
    end
  end
end
```
