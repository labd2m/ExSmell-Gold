```elixir
defmodule Auth.SessionManager do
  alias Auth.{Repo, User, Token, AuditLog, MFAProvider}

  require Logger

  @token_ttl_seconds 3_600
  @max_failed_attempts 5

  def authenticate_user(credentials, request_metadata) do
    with {:ok, user} <- resolve_user(credentials.identifier),
         :ok <- verify_password(user, credentials.password),
         :ok <- check_account_status(user),
         {:ok, mfa_result} <- verify_mfa(user, credentials.mfa_code) do
      session_token = Token.generate(user.id, @token_ttl_seconds)

      AuditLog.record(:login_success, %{
        user_id: user.id,
        ip: request_metadata.ip,
        user_agent: request_metadata.user_agent
      })

      {:ok, %{token: session_token, user: sanitize_user(user), mfa: mfa_result}}
    else
      {:error, :not_found} ->
        Logger.warning("Login attempt for unknown identifier: #{credentials.identifier}")
        AuditLog.record(:login_failed_unknown, %{identifier: credentials.identifier})
        {:error, :invalid_credentials}

      {:error, :invalid_password} ->
        Logger.warning("Invalid password for identifier: #{credentials.identifier}")
        maybe_lock_account(credentials.identifier)
        {:error, :invalid_credentials}

      {:error, :locked} ->
        Logger.warning("Login attempt on locked account: #{credentials.identifier}")
        {:error, :account_locked}

      {:error, :suspended} ->
        Logger.warning("Login attempt on suspended account: #{credentials.identifier}")
        {:error, :account_suspended}

      {:error, :unverified} ->
        {:error, :email_verification_required}

      {:error, :mfa_required} ->
        {:error, :mfa_required}

      {:error, :invalid_mfa_code} ->
        Logger.warning("Invalid MFA code for: #{credentials.identifier}")
        {:error, :invalid_mfa_code}

      {:error, :mfa_expired} ->
        {:error, :mfa_expired}
    end
  end

  defp resolve_user(identifier) do
    case Repo.get_by(User, email: String.downcase(identifier)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp verify_password(user, password) do
    if Argon2.verify_pass(password, user.password_hash) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  defp check_account_status(%User{status: :active}), do: :ok
  defp check_account_status(%User{status: :locked}), do: {:error, :locked}
  defp check_account_status(%User{status: :suspended}), do: {:error, :suspended}
  defp check_account_status(%User{status: :unverified}), do: {:error, :unverified}

  defp verify_mfa(%User{mfa_enabled: false}, _code), do: {:ok, %{method: :none}}

  defp verify_mfa(%User{mfa_enabled: true} = user, nil),
    do: {:error, :mfa_required}

  defp verify_mfa(%User{mfa_enabled: true} = user, code) do
    MFAProvider.verify(user.mfa_secret, code)
  end

  defp maybe_lock_account(identifier) do
    case Repo.get_by(User, email: String.downcase(identifier)) do
      nil ->
        :ok

      user ->
        failed = (user.failed_login_attempts || 0) + 1

        if failed >= @max_failed_attempts do
          user |> User.changeset(%{status: :locked}) |> Repo.update()
        else
          user |> User.changeset(%{failed_login_attempts: failed}) |> Repo.update()
        end
    end
  end

  defp sanitize_user(user) do
    Map.drop(user, [:password_hash, :mfa_secret, :failed_login_attempts])
  end
end
```
