# Annotated Example — Code Smell: Comments

| Field | Value |
|---|---|
| **Smell name** | Comments |
| **Expected smell location** | `AuthService.authenticate_user/2` |
| **Affected function(s)** | `authenticate_user/2` |
| **Short explanation** | The function relies on a block of plain `#` comments for its documentation rather than the `@doc` attribute, making it invisible to ExDoc and IEx introspection. |

```elixir
defmodule MyApp.AuthService do
  @moduledoc """
  Provides authentication primitives for the MyApp platform,
  including credential verification, token issuance, and session management.
  """

  alias MyApp.{Repo, User, Session, AuditLog}
  alias MyApp.Crypto.PasswordHasher
  alias MyApp.Token.JWTIssuer
  require Logger

  @max_failed_attempts 5
  @lockout_minutes 30
  @session_ttl_seconds 3_600

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `authenticate_user/2` is described only
  # VALIDATION: through plain `#` comment lines instead of an `@doc` attribute.
  # VALIDATION: ExDoc will not pick this up, and `h MyApp.AuthService.authenticate_user/2`
  # VALIDATION: in IEx will return no documentation.

  # authenticate_user/2
  #
  # Verifies a user's credentials and issues a signed JWT on success.
  #
  # Steps performed:
  #   1. Looks up the user by email.
  #   2. Checks whether the account is locked due to too many failed attempts.
  #   3. Verifies the plaintext password against the stored hash.
  #   4. Resets the failed-attempt counter on success.
  #   5. Creates a new session record and returns a signed JWT.
  #
  # Returns:
  #   {:ok, %{token: binary(), session_id: integer()}} on success
  #   {:error, :invalid_credentials} when email or password is wrong
  #   {:error, :account_locked} when the account is temporarily locked

  # VALIDATION: SMELL END
  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    with {:ok, user} <- find_user_by_email(email),
         :ok <- check_account_lock(user),
         :ok <- verify_password(password, user.password_hash) do
      :ok = reset_failed_attempts(user)
      {:ok, session} = create_session(user)
      {:ok, token} = JWTIssuer.sign(%{user_id: user.id, session_id: session.id})

      AuditLog.record(:login_success, user_id: user.id)
      Logger.info("[Auth] Successful login for user #{user.id}")

      {:ok, %{token: token, session_id: session.id}}
    else
      {:error, :user_not_found} ->
        Logger.warning("[Auth] Login attempt for unknown email: #{email}")
        {:error, :invalid_credentials}

      {:error, :account_locked} = err ->
        Logger.warning("[Auth] Locked account login attempt: #{email}")
        err

      {:error, :password_mismatch} ->
        increment_failed_attempts(email)
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Revokes a session by its ID, effectively logging the user out.

  Returns `:ok` if the session was found and revoked, or `{:error, :not_found}`
  if no matching session exists.
  """
  def revoke_session(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Session.changeset(%{revoked: true, revoked_at: DateTime.utc_now()})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Returns `true` if the given JWT token is valid and the associated session
  is still active, `false` otherwise.
  """
  def valid_token?(token) do
    with {:ok, claims} <- JWTIssuer.verify(token),
         session when not is_nil(session) <- Repo.get(Session, claims["session_id"]),
         false <- session.revoked do
      true
    else
      _ -> false
    end
  end

  ## Private

  defp find_user_by_email(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp check_account_lock(%User{failed_attempts: attempts, last_failed_at: last_failed})
       when attempts >= @max_failed_attempts do
    lockout_until = DateTime.add(last_failed, @lockout_minutes * 60, :second)

    if DateTime.compare(DateTime.utc_now(), lockout_until) == :lt do
      {:error, :account_locked}
    else
      :ok
    end
  end

  defp check_account_lock(_user), do: :ok

  defp verify_password(password, hash) do
    if PasswordHasher.verify(password, hash) do
      :ok
    else
      {:error, :password_mismatch}
    end
  end

  defp reset_failed_attempts(user) do
    user |> User.changeset(%{failed_attempts: 0, last_failed_at: nil}) |> Repo.update!()
    :ok
  end

  defp increment_failed_attempts(email) do
    case Repo.get_by(User, email: email) do
      nil ->
        :ok

      user ->
        user
        |> User.changeset(%{
          failed_attempts: (user.failed_attempts || 0) + 1,
          last_failed_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  defp create_session(user) do
    %Session{}
    |> Session.changeset(%{
      user_id: user.id,
      expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second),
      revoked: false
    })
    |> Repo.insert()
  end
end
```
