```elixir
defmodule MyApp.AuthHandler do
  @moduledoc """
  Handles authentication-related actions for the application.
  Supports login, password reset flows, and token management.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Accounts.{User, PasswordResetToken, ApiToken}
  alias MyApp.Auth.{PasswordHasher, SessionStore, TokenGenerator}
  alias MyApp.Notifications.Mailer

  @max_login_attempts 5
  @reset_token_ttl_hours 2
  @session_ttl_seconds 86_400

  @doc """
  Executes an authentication action.

  Accepts one of:
  - `%{action: :login, email: email, password: password}`
  - `%{action: :request_password_reset, email: email}`
  - `%{action: :revoke_api_token, token_id: id, user_id: uid}`

  ## Examples

      iex> MyApp.AuthHandler.execute(%{action: :login, email: "user@example.com", password: "secret"})
      {:ok, %{session_token: "..."}}

  """

  def execute(%{action: :login, email: email, password: password}) do
    Logger.info("Login attempt for #{email}")

    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        Logger.warn("Login failed: user not found for #{email}")
        {:error, :invalid_credentials}

      %User{locked_at: locked_at} when not is_nil(locked_at) ->
        Logger.warn("Login attempt on locked account: #{email}")
        {:error, :account_locked}

      %User{failed_attempts: attempts} when attempts >= @max_login_attempts ->
        Logger.warn("Account #{email} exceeded login attempts, locking")
        Repo.update!(User.lock_changeset(Repo.get_by!(User, email: email)))
        {:error, :account_locked}

      %User{password_hash: hash} = user ->
        if PasswordHasher.verify(password, hash) do
          session_token = TokenGenerator.generate(:session)

          SessionStore.put(session_token, %{
            user_id: user.id,
            roles: user.roles,
            inserted_at: System.system_time(:second)
          }, ttl: @session_ttl_seconds)

          Repo.update!(User.reset_attempts_changeset(user))
          Logger.info("Successful login for #{email}")
          {:ok, %{session_token: session_token, user_id: user.id}}
        else
          Repo.update!(User.increment_attempts_changeset(user))
          Logger.warn("Invalid password for #{email}")
          {:error, :invalid_credentials}
        end
    end
  end

  def execute(%{action: :request_password_reset, email: email}) do
    Logger.info("Password reset requested for #{email}")

    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        Logger.warn("Password reset requested for unknown email: #{email}")
        {:ok, :reset_email_sent}

      %User{locked_at: locked_at} when not is_nil(locked_at) ->
        Logger.warn("Password reset requested for locked account: #{email}")
        {:error, :account_locked}

      user ->
        Repo.delete_all(
          from t in PasswordResetToken,
            where: t.user_id == ^user.id and t.used == false
        )

        raw_token = TokenGenerator.generate(:reset)
        expires_at = DateTime.add(DateTime.utc_now(), @reset_token_ttl_hours * 3600, :second)

        {:ok, token_record} =
          Repo.insert(
            PasswordResetToken.changeset(%PasswordResetToken{}, %{
              user_id: user.id,
              token_hash: PasswordHasher.hash(raw_token),
              expires_at: expires_at
            })
          )

        Mailer.send_password_reset(user.email, raw_token)
        Logger.info("Password reset email sent to #{email}, token id: #{token_record.id}")
        {:ok, :reset_email_sent}
    end
  end

  def execute(%{action: :revoke_api_token, token_id: token_id, user_id: user_id}) do
    Logger.info("Revoking API token #{token_id} for user #{user_id}")

    case Repo.get_by(ApiToken, id: token_id, user_id: user_id, revoked: false) do
      nil ->
        Logger.warn("API token #{token_id} not found or already revoked for user #{user_id}")
        {:error, :token_not_found}

      token ->
        {:ok, updated} =
          Repo.update(
            ApiToken.changeset(token, %{
              revoked: true,
              revoked_at: DateTime.utc_now()
            })
          )

        Logger.info("API token #{token_id} successfully revoked")
        {:ok, updated}
    end
  end

end
```
