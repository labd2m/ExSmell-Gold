```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Manages the creation, validation, and termination of user sessions,
  including multi-factor authentication handling.
  """

  require Logger

  alias Auth.{Session, MfaChallenge, AuditLog}
  alias Accounts.{User, MfaConfig, DeviceRegistry}
  alias Security.{PasswordHasher, TokenIssuer}

  @session_ttl_seconds 86_400
  @mfa_grace_period_minutes 30

  def validate_session(token) do
    case Session.fetch_by_token(token) do
      {:ok, session} when session.expires_at > DateTime.utc_now() ->
        {:ok, session}

      {:ok, _expired} ->
        {:error, :session_expired}

      {:error, _} ->
        {:error, :invalid_session}
    end
  end

  def terminate_session(session_id, actor_id) do
    with {:ok, session} <- Session.fetch(session_id) do
      Session.persist(%{session | status: :terminated, terminated_at: DateTime.utc_now()})
      AuditLog.record(:session_terminated, %{session_id: session_id, actor_id: actor_id})
    end
  end

  def terminate_all_sessions(user_id) do
    user_id
    |> Session.list_active()
    |> Enum.each(fn session ->
      Session.persist(%{session | status: :terminated, terminated_at: DateTime.utc_now()})
    end)

    AuditLog.record(:all_sessions_terminated, %{user_id: user_id})
    :ok
  end

  def create_session(email, password, device_fingerprint) do
    user = User.find_by_email(email)

    cond do
      is_nil(user) ->
        {:error, :invalid_credentials}

      user.account_status == :locked ->
        {:error, :account_locked}

      user.account_status == :suspended ->
        {:error, :account_suspended}

      not PasswordHasher.verify(password, user.password_hash) ->
        AuditLog.record(:failed_login, %{user_id: user.id, email: email})
        {:error, :invalid_credentials}

      true ->
        mfa_config = MfaConfig.find(user.mfa_config_id)

        if mfa_config.enabled == true do
          device_entry = DeviceRegistry.fetch(device_fingerprint, user.id)

          device_trusted? =
            not is_nil(device_entry) &&
              device_entry.trusted == true &&
              DateTime.diff(DateTime.utc_now(), device_entry.last_seen_at, :minute) <
                @mfa_grace_period_minutes

          if device_trusted? do
            issue_session(user, device_fingerprint)
          else
            challenge = MfaChallenge.create(user.id, mfa_config.method, mfa_config.secret)
            {:mfa_required, challenge.token}
          end
        else
          issue_session(user, device_fingerprint)
        end
    end
  end

  def complete_mfa(challenge_token, otp_code) do
    with {:ok, challenge} <- MfaChallenge.fetch(challenge_token),
         :ok              <- MfaChallenge.verify(challenge, otp_code),
         {:ok, user}      <- User.fetch(challenge.user_id) do
      DeviceRegistry.mark_trusted(challenge.device_fingerprint, user.id)
      issue_session(user, challenge.device_fingerprint)
    end
  end

  def refresh_session(token) do
    with {:ok, session} <- Session.fetch_by_token(token),
         true           <- session.status == :active do
      new_expiry = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)
      Session.persist(%{session | expires_at: new_expiry})
    else
      false -> {:error, :session_not_active}
      err   -> err
    end
  end


  defp issue_session(user, device_fingerprint) do
    token = TokenIssuer.generate()

    session = %Session{
      user_id:            user.id,
      token:              token,
      device_fingerprint: device_fingerprint,
      status:             :active,
      expires_at:         DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second),
      created_at:         DateTime.utc_now()
    }

    with {:ok, saved} <- Session.persist(session) do
      AuditLog.record(:session_created, %{user_id: user.id, session_id: saved.id})
      {:ok, saved}
    end
  end
end
```
