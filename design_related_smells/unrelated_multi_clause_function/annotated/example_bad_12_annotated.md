# Annotated Example 12

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `AuthService.handle/1`
- **Affected function(s):** `handle/1`
- **Short explanation:** `handle/1` conflates login, password reset, and session revocation — three distinct authentication workflows — into one multi-clause function. The clauses share no logic and represent entirely separate security concerns.

```elixir
defmodule AuthService do
  @moduledoc """
  Handles authentication operations including login, password resets,
  and session management for the platform.
  """

  alias AuthService.{
    LoginRequest,
    PasswordResetRequest,
    SessionRevocation,
    UserStore,
    SessionStore,
    TokenIssuer,
    Mailer,
    RateLimiter
  }

  require Logger

  @max_login_attempts 5

  @doc """
  Handle an authentication action.

  Accepts a `%LoginRequest{}`, `%PasswordResetRequest{}`, or
  `%SessionRevocation{}` struct and performs the corresponding action.

  ## Examples

      iex> AuthService.handle(%LoginRequest{email: "user@example.com", password: "secret"})
      {:ok, %{token: "...", expires_at: ~U[2024-12-31 00:00:00Z]}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because login credential validation, password
  # reset token issuance, and session revocation are independent security
  # workflows with distinct audit, rate-limiting, and side-effect requirements,
  # yet they are collapsed into one `handle/1` multi-clause function.

  def handle(%LoginRequest{email: email, password: password, ip: ip}) do
    with :ok <- RateLimiter.check(:login, ip, @max_login_attempts),
         {:ok, user} <- UserStore.find_by_email(email),
         :ok <- verify_password(password, user.password_hash),
         :ok <- check_account_active(user),
         {:ok, token, claims} <- TokenIssuer.generate_access_token(user.id),
         {:ok, _session} <-
           SessionStore.create(%{
             user_id: user.id,
             token: token,
             ip: ip,
             created_at: DateTime.utc_now()
           }) do
      Logger.info("User #{user.id} logged in from #{ip}")
      {:ok, %{token: token, expires_at: claims["exp"]}}
    else
      {:error, :rate_limited} -> {:error, :too_many_attempts}
      {:error, :not_found} -> {:error, :invalid_credentials}
      {:error, :invalid_password} -> {:error, :invalid_credentials}
      {:error, :inactive} -> {:error, :account_inactive}
      error -> error
    end
  end

  # handle password reset request initiated by the user
  def handle(%PasswordResetRequest{email: email}) do
    with {:ok, user} <- UserStore.find_by_email(email),
         :ok <- check_account_active(user),
         {:ok, reset_token} <- TokenIssuer.generate_reset_token(user.id),
         :ok <-
           UserStore.store_reset_token(user.id, reset_token, ttl_minutes: 30),
         :ok <- Mailer.send_password_reset(user.email, reset_token) do
      Logger.info("Password reset requested for user #{user.id}")
      {:ok, :reset_email_sent}
    else
      {:error, :not_found} ->
        # Avoid leaking whether the email exists
        {:ok, :reset_email_sent}

      error ->
        error
    end
  end

  # handle session revocation (logout or admin forced sign-out)
  def handle(%SessionRevocation{session_id: session_id, revoked_by: revoked_by}) do
    with {:ok, session} <- SessionStore.fetch(session_id),
         :ok <- SessionStore.revoke(session_id),
         :ok <-
           AuditLog.append(:session_revoked, %{
             session_id: session_id,
             user_id: session.user_id,
             revoked_by: revoked_by,
             revoked_at: DateTime.utc_now()
           }) do
      Logger.info("Session #{session_id} revoked by #{inspect(revoked_by)}")
      {:ok, :session_revoked}
    end
  end

  # VALIDATION: SMELL END

  defp verify_password(plain, hash) do
    if Bcrypt.verify_pass(plain, hash) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  defp check_account_active(%{status: :active}), do: :ok
  defp check_account_active(_), do: {:error, :inactive}
end
```
