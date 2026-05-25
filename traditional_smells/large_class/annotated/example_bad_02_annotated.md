# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `AuthManager` module
- **Affected function(s):** `register_user/1`, `authenticate/2`, `issue_token/1`, `verify_token/1`, `revoke_token/1`, `initiate_password_reset/1`, `complete_password_reset/2`, `rotate_refresh_token/1`, `lock_account/2`, `unlock_account/1`, `log_auth_event/3`, `list_active_sessions/1`
- **Short explanation:** `AuthManager` mixes registration, credential verification, JWT token lifecycle, password reset flows, account locking, and audit logging. These are separate concerns that each warrant their own module (e.g., `Registration`, `TokenStore`, `PasswordReset`, `AccountLock`, `AuthAudit`), making the current single module poorly cohesive and hard to maintain.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because AuthManager bundles user registration,
# credential authentication, JWT issuance/verification/revocation, password-reset
# flows, account locking, session listing, and audit logging — at least six
# distinct responsibilities — into one module that should be split.
defmodule MyApp.AuthManager do
  @moduledoc """
  Central module for all authentication and authorization operations.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Accounts.{User, PasswordResetToken, RefreshToken, AuthEvent}
  alias MyApp.Crypto

  @access_token_ttl_seconds  900        # 15 min
  @refresh_token_ttl_days    30
  @max_failed_attempts       5
  @reset_token_ttl_minutes   20

  # -------------------------------------------------------------------
  # Registration
  # -------------------------------------------------------------------

  def register_user(attrs) do
    hashed = Crypto.hash_password(attrs[:password] || "")

    changeset =
      %User{}
      |> User.registration_changeset(Map.put(attrs, :password_hash, hashed))

    case Repo.insert(changeset) do
      {:ok, user} ->
        log_auth_event(user.id, :registered, %{ip: attrs[:ip]})
        {:ok, user}

      {:error, _} = err ->
        err
    end
  end

  # -------------------------------------------------------------------
  # Credential authentication
  # -------------------------------------------------------------------

  def authenticate(email, password) do
    user = Repo.get_by(User, email: String.downcase(email))

    cond do
      is_nil(user) ->
        Crypto.dummy_check()
        {:error, :invalid_credentials}

      user.locked ->
        {:error, :account_locked}

      not Crypto.verify_password(password, user.password_hash) ->
        handle_failed_attempt(user)
        {:error, :invalid_credentials}

      true ->
        Repo.update!(User.changeset(user, %{failed_attempts: 0, last_login_at: DateTime.utc_now()}))
        log_auth_event(user.id, :login_success, %{})
        {:ok, user}
    end
  end

  defp handle_failed_attempt(%User{} = user) do
    new_count = user.failed_attempts + 1
    updates   = %{failed_attempts: new_count}

    updates =
      if new_count >= @max_failed_attempts,
        do: Map.put(updates, :locked, true),
        else: updates

    Repo.update!(User.changeset(user, updates))
    log_auth_event(user.id, :login_failure, %{attempt: new_count})

    if new_count >= @max_failed_attempts,
      do: log_auth_event(user.id, :account_locked, %{reason: :too_many_failures})
  end

  # -------------------------------------------------------------------
  # JWT token management
  # -------------------------------------------------------------------

  def issue_token(%User{} = user) do
    access_claims = %{
      sub:  user.id,
      role: user.role,
      exp:  System.system_time(:second) + @access_token_ttl_seconds
    }

    {:ok, access_token}  = Crypto.sign_jwt(access_claims)
    {:ok, refresh_token} = Crypto.generate_opaque_token(48)

    expiry = DateTime.add(DateTime.utc_now(), @refresh_token_ttl_days * 86_400, :second)

    Repo.insert!(%RefreshToken{
      user_id:    user.id,
      token_hash: Crypto.hash_token(refresh_token),
      expires_at: expiry
    })

    {:ok, %{access_token: access_token, refresh_token: refresh_token}}
  end

  def verify_token(access_token) do
    case Crypto.verify_jwt(access_token) do
      {:ok, %{"sub" => user_id, "exp" => exp}} ->
        if exp < System.system_time(:second) do
          {:error, :token_expired}
        else
          {:ok, user_id}
        end

      {:error, _} ->
        {:error, :invalid_token}
    end
  end

  def revoke_token(refresh_token) do
    hash = Crypto.hash_token(refresh_token)

    case Repo.get_by(RefreshToken, token_hash: hash) do
      nil   -> {:error, :not_found}
      token ->
        Repo.delete!(token)
        {:ok, :revoked}
    end
  end

  def rotate_refresh_token(old_refresh_token) do
    hash = Crypto.hash_token(old_refresh_token)

    case Repo.get_by(RefreshToken, token_hash: hash) do
      nil ->
        {:error, :invalid_token}

      old_token ->
        if DateTime.compare(old_token.expires_at, DateTime.utc_now()) == :lt do
          Repo.delete!(old_token)
          {:error, :token_expired}
        else
          user = Repo.get!(User, old_token.user_id)
          Repo.delete!(old_token)
          issue_token(user)
        end
    end
  end

  # -------------------------------------------------------------------
  # Password reset
  # -------------------------------------------------------------------

  def initiate_password_reset(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        {:ok, :noop}

      user ->
        {:ok, raw_token} = Crypto.generate_opaque_token(32)
        expiry = DateTime.add(DateTime.utc_now(), @reset_token_ttl_minutes * 60, :second)

        Repo.insert!(%PasswordResetToken{
          user_id:    user.id,
          token_hash: Crypto.hash_token(raw_token),
          expires_at: expiry
        })

        MyApp.Mailer.deliver(%{
          to:      user.email,
          subject: "Reset your password",
          body:    "Use this link to reset: https://app.example.com/reset?token=#{raw_token}"
        })

        log_auth_event(user.id, :password_reset_requested, %{})
        {:ok, :sent}
    end
  end

  def complete_password_reset(raw_token, new_password) do
    hash = Crypto.hash_token(raw_token)

    with %PasswordResetToken{} = prt <- Repo.get_by(PasswordResetToken, token_hash: hash),
         :lt <- DateTime.compare(DateTime.utc_now(), prt.expires_at),
         user <- Repo.get!(User, prt.user_id) do
      new_hash = Crypto.hash_password(new_password)
      Repo.update!(User.changeset(user, %{password_hash: new_hash, failed_attempts: 0, locked: false}))
      Repo.delete!(prt)
      log_auth_event(user.id, :password_reset_completed, %{})
      {:ok, :password_updated}
    else
      nil -> {:error, :invalid_token}
      _   -> {:error, :token_expired}
    end
  end

  # -------------------------------------------------------------------
  # Account locking
  # -------------------------------------------------------------------

  def lock_account(%User{} = user, reason) do
    Repo.update!(User.changeset(user, %{locked: true, lock_reason: reason}))
    log_auth_event(user.id, :account_locked, %{reason: reason, manual: true})
    :ok
  end

  def unlock_account(%User{} = user) do
    Repo.update!(User.changeset(user, %{locked: false, failed_attempts: 0, lock_reason: nil}))
    log_auth_event(user.id, :account_unlocked, %{})
    :ok
  end

  # -------------------------------------------------------------------
  # Audit logging
  # -------------------------------------------------------------------

  def log_auth_event(user_id, event_type, metadata) do
    Repo.insert!(%AuthEvent{
      user_id:    user_id,
      event_type: event_type,
      metadata:   metadata,
      occurred_at: DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Session listing
  # -------------------------------------------------------------------

  def list_active_sessions(user_id) do
    from(rt in RefreshToken,
      where: rt.user_id == ^user_id and rt.expires_at > ^DateTime.utc_now(),
      order_by: [desc: rt.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn rt ->
      %{token_id: rt.id, issued_at: rt.inserted_at, expires_at: rt.expires_at}
    end)
  end
end
# VALIDATION: SMELL END
```
