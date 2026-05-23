# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Auth.PasswordReset.reset/2`
- **Affected function(s):** `reset/2`
- **Short explanation:** The `reset/2` function manages token lookup, expiry checking, new password validation, password hash update, token invalidation, active session revocation, security alert email, and audit recording all in a single function body — too many distinct operations collapsed into one place.

---

```elixir
defmodule Auth.PasswordReset do
  @moduledoc """
  Handles the full password reset flow: token validation, password update,
  session revocation, and security notification.
  """

  alias Auth.{User, PasswordResetToken, Session, AuditLog, Repo}
  alias Integrations.Mailer
  require Logger

  @min_password_length 10
  @token_expiry_hours 2

  def request_reset(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil  -> {:ok, :noop}
      user ->
        raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        expires_at = DateTime.add(DateTime.utc_now(), @token_expiry_hours * 3600, :second)
        Repo.insert!(%PasswordResetToken{user_id: user.id, token: raw, expires_at: expires_at, used: false})
        Mailer.send_password_reset(%{to: user.email, token: raw})
        {:ok, :sent}
    end
  end

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `reset/2` is a single function that performs
  # VALIDATION: token validation, expiry check, password strength enforcement,
  # VALIDATION: hash update, token invalidation, bulk session revocation, security
  # VALIDATION: email delivery, and audit recording without delegating any step.
  def reset(raw_token, new_password) do
    Logger.info("Processing password reset for token hash=#{:crypto.hash(:sha256, raw_token) |> Base.encode16()}")

    # --- Look up token ---
    case Repo.get_by(PasswordResetToken, token: raw_token) do
      nil ->
        {:error, :invalid_token}

      %PasswordResetToken{used: true} ->
        {:error, :token_already_used}

      %PasswordResetToken{} = token_record ->
        # --- Check expiry ---
        if DateTime.compare(DateTime.utc_now(), token_record.expires_at) == :gt do
          {:error, :token_expired}
        else
          # --- Validate new password ---
          password_issues =
            []
            |> then(fn acc ->
              if String.length(new_password) < @min_password_length,
                do: [:too_short | acc], else: acc
            end)
            |> then(fn acc ->
              if String.match?(new_password, ~r/[A-Z]/), do: acc, else: [:missing_uppercase | acc]
            end)
            |> then(fn acc ->
              if String.match?(new_password, ~r/\d/), do: acc, else: [:missing_digit | acc]
            end)
            |> then(fn acc ->
              if String.match?(new_password, ~r/[!@#$%^&*()]/), do: acc, else: [:missing_special | acc]
            end)

          if password_issues != [] do
            {:error, {:password_policy_violation, password_issues}}
          else
            user = Repo.get!(User, token_record.user_id)

            # --- Update password ---
            new_hash = Bcrypt.hash_pwd_salt(new_password)

            user
            |> User.changeset(%{
              password_hash: new_hash,
              password_changed_at: DateTime.utc_now(),
              force_password_change: false
            })
            |> Repo.update!()

            # --- Invalidate token ---
            token_record
            |> PasswordResetToken.changeset(%{used: true, used_at: DateTime.utc_now()})
            |> Repo.update!()

            # --- Revoke all active sessions ---
            sessions =
              Session
              |> Session.for_user(user.id)
              |> Session.active()
              |> Repo.all()

            revoked_count = length(sessions)
            Enum.each(sessions, fn session ->
              session
              |> Session.changeset(%{revoked: true, revoked_reason: :password_changed})
              |> Repo.update!()
            end)

            Logger.info("Revoked #{revoked_count} session(s) for user #{user.id} after password reset")

            # --- Send security alert ---
            case Mailer.send_password_change_alert(%{
                   to: user.email,
                   full_name: user.full_name,
                   changed_at: DateTime.utc_now()
                 }) do
              {:ok, _}       -> :ok
              {:error, err}  -> Logger.warning("Security alert email failed for user #{user.id}: #{inspect(err)}")
            end

            # --- Audit ---
            AuditLog.record(%{
              user_id: user.id,
              action: "password_reset",
              metadata: %{sessions_revoked: revoked_count}
            })

            Logger.info("Password reset completed for user #{user.id}")
            {:ok, :password_reset}
          end
        end
    end
  end
  # VALIDATION: SMELL END
end
```
