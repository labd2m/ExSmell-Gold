# Annotated Example – Code Smell

| Field              | Value                                                                            |
|--------------------|----------------------------------------------------------------------------------|
| **Smell name**     | Long Function                                                                    |
| **Location**       | `Auth.SessionManager.create_session/2`                                           |
| **Affected fn(s)** | `create_session/2`                                                               |
| **Explanation**    | `create_session/2` performs credential verification, MFA validation, brute-force lockout logic, device fingerprinting, session token generation, persistence, audit logging, and welcome-back notification — all in a single body of well over 90 lines. Each stage is a standalone concern; piling them together makes the function hard to test in isolation and difficult to read without following the inline section comments, which are themselves a code-smell signal. |

```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Manages user authentication sessions including MFA, device tracking, and audit trails.
  """

  require Logger

  alias Auth.{User, Session, AuditLog, DeviceFingerprint, Repo, Notifications}
  alias Auth.{PasswordHasher, TokenGenerator, MFA}

  @max_failed_attempts 5
  @lockout_minutes 15
  @session_ttl_hours 8
  @remember_me_ttl_days 30

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `create_session/2` handles too many unrelated
  # responsibilities in a single body: credential lookup, password verification,
  # lockout enforcement, MFA challenge, device fingerprinting, token minting,
  # persistence, audit logging, and push notification — all inlined without
  # delegation to focused private helpers.  The function is approximately 100 lines
  # and requires section comments to understand its flow.
  def create_session(credentials, request_meta) do
    %{email: email, password: password} = credentials
    %{ip: ip, user_agent: user_agent, remember_me: remember_me} = request_meta

    # --- 1. Locate the user account ---
    user = Repo.get_by(User, email: String.downcase(email))

    if is_nil(user) do
      Logger.warn("Login attempt for unknown email=#{email} from ip=#{ip}")
      {:error, :invalid_credentials}
    end

    # --- 2. Enforce account lockout policy ---
    lockout_expires_at =
      if user.failed_attempts >= @max_failed_attempts and not is_nil(user.locked_at) do
        NaiveDateTime.add(user.locked_at, @lockout_minutes * 60, :second)
      else
        nil
      end

    if lockout_expires_at && NaiveDateTime.compare(NaiveDateTime.utc_now(), lockout_expires_at) == :lt do
      remaining = NaiveDateTime.diff(lockout_expires_at, NaiveDateTime.utc_now(), :second)
      Logger.warn("Locked account login attempt user_id=#{user.id} ip=#{ip}")
      {:error, {:account_locked, remaining}}
    end

    # --- 3. Verify password ---
    unless PasswordHasher.verify(password, user.password_hash) do
      new_attempts = user.failed_attempts + 1

      lock_attrs =
        if new_attempts >= @max_failed_attempts do
          %{failed_attempts: new_attempts, locked_at: NaiveDateTime.utc_now()}
        else
          %{failed_attempts: new_attempts}
        end

      Repo.update!(User.changeset(user, lock_attrs))

      Repo.insert!(%AuditLog{
        user_id: user.id,
        event: :login_failed,
        ip_address: ip,
        user_agent: user_agent,
        inserted_at: NaiveDateTime.utc_now()
      })

      {:error, :invalid_credentials}
    end

    # --- 4. Check MFA requirement ---
    if user.mfa_enabled do
      otp_code = Map.get(credentials, :otp_code)

      if is_nil(otp_code) do
        pending_token = TokenGenerator.generate(:mfa_pending, user.id)
        {:mfa_required, pending_token}
      end

      unless MFA.verify_totp(user.mfa_secret, otp_code) do
        Repo.insert!(%AuditLog{
          user_id: user.id,
          event: :mfa_failed,
          ip_address: ip,
          user_agent: user_agent,
          inserted_at: NaiveDateTime.utc_now()
        })
        {:error, :invalid_mfa_code}
      end
    end

    # --- 5. Determine device trust ---
    fingerprint = DeviceFingerprint.compute(user_agent, ip)
    is_known_device = Repo.exists?(
      from d in DeviceFingerprint,
        where: d.user_id == ^user.id and d.fingerprint == ^fingerprint
    )

    unless is_known_device do
      Repo.insert!(%DeviceFingerprint{
        user_id: user.id,
        fingerprint: fingerprint,
        user_agent: user_agent,
        first_seen_ip: ip,
        inserted_at: NaiveDateTime.utc_now()
      })
    end

    # --- 6. Mint session token ---
    ttl_hours = if remember_me, do: @remember_me_ttl_days * 24, else: @session_ttl_hours
    expires_at = NaiveDateTime.add(NaiveDateTime.utc_now(), ttl_hours * 3600, :second)
    token = TokenGenerator.generate(:session, user.id)

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        user_id: user.id,
        token: token,
        ip_address: ip,
        user_agent: user_agent,
        fingerprint: fingerprint,
        remember_me: remember_me,
        expires_at: expires_at
      })
      |> Repo.insert()

    # --- 7. Reset failed attempts and update last login ---
    Repo.update!(User.changeset(user, %{
      failed_attempts: 0,
      locked_at: nil,
      last_login_at: NaiveDateTime.utc_now(),
      last_login_ip: ip
    }))

    # --- 8. Emit audit log entry ---
    Repo.insert!(%AuditLog{
      user_id: user.id,
      event: :login_success,
      ip_address: ip,
      user_agent: user_agent,
      metadata: %{session_id: session.id, remember_me: remember_me},
      inserted_at: NaiveDateTime.utc_now()
    })

    # --- 9. Send new-device notification when applicable ---
    unless is_known_device do
      Notifications.send_new_device_alert(user, %{ip: ip, user_agent: user_agent})
    end

    Logger.info("Session created user_id=#{user.id} session_id=#{session.id}")
    {:ok, session}
  end
  # VALIDATION: SMELL END

  def invalidate_session(token) do
    case Repo.get_by(Session, token: token) do
      nil -> {:error, :not_found}
      session -> Repo.update!(Session.changeset(session, %{revoked_at: NaiveDateTime.utc_now()}))
    end
  end
end
```
