# Annotated Example 17

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `UserManager.perform/1`
- **Affected function(s):** `perform/1`
- **Short explanation:** `perform/1` handles user registration, account suspension, and profile merging — three independent user management operations — grouped into one multi-clause function. Each clause involves distinct validation, persistence, and notification logic with no shared interface.

```elixir
defmodule UserManager do
  @moduledoc """
  Core user management operations for the platform, including registration,
  account suspension, and profile merging after deduplication.
  """

  alias UserManager.{
    RegistrationRequest,
    SuspensionRequest,
    MergeRequest,
    UserStore,
    EmailVerification,
    AuditLog,
    Mailer,
    PermissionsCache
  }

  require Logger

  @doc """
  Perform a user management operation.

  Accepts a `%RegistrationRequest{}`, `%SuspensionRequest{}`, or
  `%MergeRequest{}` and applies the appropriate action.

  ## Examples

      iex> UserManager.perform(%RegistrationRequest{email: "alice@example.com", name: "Alice"})
      {:ok, %User{id: 1, email: "alice@example.com"}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because user registration, account suspension,
  # and profile merging are entirely separate user management workflows with
  # different actors, authorization requirements, and side effects. Using a
  # single `perform/1` to cover all three conflates unrelated logic.

  def perform(%RegistrationRequest{
        email: email,
        name: name,
        password: password,
        plan: plan,
        referral_code: referral_code
      }) do
    with :ok <- validate_email_unique(email),
         :ok <- validate_password_strength(password),
         {:ok, hashed} <- hash_password(password),
         {:ok, user} <-
           UserStore.create(%{
             email: email,
             name: name,
             password_hash: hashed,
             plan: plan,
             status: :pending_verification,
             referred_by: resolve_referral(referral_code)
           }),
         {:ok, token} <- EmailVerification.generate_token(user.id),
         :ok <- Mailer.send_verification_email(email, token) do
      Logger.info("User #{user.id} registered with email #{email}")
      {:ok, user}
    end
  end

  # perform account suspension initiated by admin or fraud detection system
  def perform(%SuspensionRequest{
        user_id: user_id,
        reason: reason,
        suspended_by: suspended_by,
        notify_user: notify_user
      })
      when reason in [:fraud, :policy_violation, :payment_failure, :admin_request] do
    with {:ok, user} <- UserStore.find(user_id),
         :ok <- validate_suspendable(user),
         {:ok, updated} <-
           UserStore.update(user_id, %{
             status: :suspended,
             suspended_reason: reason,
             suspended_at: DateTime.utc_now()
           }),
         :ok <- PermissionsCache.invalidate(user_id),
         :ok <-
           AuditLog.append(:user_suspended, %{
             user_id: user_id,
             reason: reason,
             by: suspended_by
           }),
         :ok <- maybe_notify_suspension(notify_user, user.email, reason) do
      Logger.warning("User #{user_id} suspended: #{reason} by #{inspect(suspended_by)}")
      {:ok, updated}
    end
  end

  # perform merge of duplicate user profiles, keeping primary
  def perform(%MergeRequest{
        primary_user_id: primary_id,
        secondary_user_id: secondary_id,
        requested_by: requested_by
      })
      when primary_id != secondary_id do
    with {:ok, primary} <- UserStore.find(primary_id),
         {:ok, secondary} <- UserStore.find(secondary_id),
         :ok <- validate_both_active(primary, secondary),
         :ok <- UserStore.reassign_resources(secondary_id, primary_id),
         {:ok, _} <-
           UserStore.update(secondary_id, %{
             status: :merged,
             merged_into: primary_id,
             merged_at: DateTime.utc_now()
           }),
         :ok <-
           AuditLog.append(:profiles_merged, %{
             primary: primary_id,
             secondary: secondary_id,
             by: requested_by
           }),
         :ok <- Mailer.send_merge_notification(primary.email) do
      Logger.info("Merged user #{secondary_id} into #{primary_id}")
      {:ok, primary}
    end
  end

  # VALIDATION: SMELL END

  defp validate_email_unique(email) do
    case UserStore.find_by_email(email) do
      {:ok, _} -> {:error, :email_already_registered}
      {:error, :not_found} -> :ok
    end
  end

  defp validate_password_strength(password) when byte_size(password) >= 10, do: :ok
  defp validate_password_strength(_), do: {:error, :password_too_short}

  defp hash_password(password), do: {:ok, Bcrypt.hash_pwd_salt(password)}

  defp resolve_referral(nil), do: nil
  defp resolve_referral(code), do: UserStore.find_id_by_referral_code(code)

  defp validate_suspendable(%{status: :active}), do: :ok
  defp validate_suspendable(%{status: s}), do: {:error, {:cannot_suspend, s}}

  defp validate_both_active(%{status: :active}, %{status: :active}), do: :ok
  defp validate_both_active(_, _), do: {:error, :both_users_must_be_active}

  defp maybe_notify_suspension(true, email, reason), do: Mailer.send_suspension_notice(email, reason)
  defp maybe_notify_suspension(false, _email, _reason), do: :ok
end
```
