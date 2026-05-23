# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Auth.SessionManager.create_session/2`
- **Affected function(s):** `create_session/2`
- **Short explanation:** `create_session/2` handles credential lookup, password verification, multi-factor validation, rate-limit enforcement, session token generation, device fingerprinting, and audit logging in a single function — a textbook Long Function accumulating multiple distinct responsibilities.

---

```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Manages user authentication sessions including MFA, device
  fingerprinting, and rate-limit enforcement.
  """

  require Logger

  alias Auth.{User, MFAToken, Session, RateLimiter, AuditLog}
  alias Comeonin.Bcrypt

  @session_ttl_seconds 86_400
  @max_login_attempts  5
  @lockout_window_secs 900

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `create_session/2` performs at least
  # seven distinct operations (rate-limit check, user lookup, password verify,
  # MFA check, token generation, device fingerprint recording, audit log write)
  # without delegating any of them to focused helper functions, making the
  # function body far exceed ten lines and hard to reason about or test in
  # isolation.
  def create_session(credentials, request_meta) do
    ip_address  = Map.fetch!(request_meta, :ip)
    user_agent  = Map.get(request_meta, :user_agent, "unknown")
    device_id   = Map.get(request_meta, :device_id)

    # 1. Rate-limit check
    attempt_key = "login_attempts:#{ip_address}"

    case RateLimiter.get_count(attempt_key) do
      {:ok, count} when count >= @max_login_attempts ->
        Logger.warning("Blocked login from #{ip_address} — too many attempts")
        {:error, :too_many_attempts}

      _ ->
        # 2. Look up the user by e-mail
        case User.find_by_email(credentials.email) do
          nil ->
            RateLimiter.increment(attempt_key, @lockout_window_secs)
            {:error, :invalid_credentials}

          %User{active: false} ->
            {:error, :account_disabled}

          %User{} = user ->
            # 3. Verify the password
            unless Bcrypt.verify_pass(credentials.password, user.password_hash) do
              RateLimiter.increment(attempt_key, @lockout_window_secs)
              {:error, :invalid_credentials}
            else
              RateLimiter.reset(attempt_key)

              # 4. Check MFA if enabled
              mfa_result =
                if user.mfa_enabled do
                  case credentials[:otp_code] do
                    nil ->
                      {:error, :mfa_required}

                    otp_code ->
                      case MFAToken.verify(user.id, otp_code) do
                        :ok              -> :ok
                        {:error, reason} -> {:error, reason}
                      end
                  end
                else
                  :ok
                end

              case mfa_result do
                {:error, reason} ->
                  {:error, reason}

                :ok ->
                  # 5. Generate session token
                  token  = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
                  expiry = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

                  session = %Session{
                    user_id:    user.id,
                    token:      token,
                    ip_address: ip_address,
                    user_agent: user_agent,
                    expires_at: expiry,
                    inserted_at: DateTime.utc_now()
                  }

                  case Session.insert(session) do
                    {:error, reason} ->
                      Logger.error("Failed to persist session: #{inspect(reason)}")
                      {:error, :session_persistence_failed}

                    {:ok, saved_session} ->
                      # 6. Record device fingerprint
                      if device_id do
                        known_devices = User.known_device_ids(user.id)

                        unless device_id in known_devices do
                          Logger.info("New device #{device_id} for user #{user.id}")
                          User.register_device(user.id, device_id, ip_address, user_agent)
                        end
                      end

                      # 7. Write audit log
                      audit = %AuditLog{
                        user_id:    user.id,
                        action:     "login",
                        ip_address: ip_address,
                        metadata:   %{device_id: device_id, mfa_used: user.mfa_enabled},
                        inserted_at: DateTime.utc_now()
                      }

                      case AuditLog.insert(audit) do
                        {:error, r} ->
                          Logger.warning("Audit log insert failed: #{inspect(r)}")
                        _ ->
                          :ok
                      end

                      {:ok, %{token: token, expires_at: expiry, user_id: user.id}}
                  end
              end
            end
        end
    end
  end
  # VALIDATION: SMELL END
end
```
