```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Manages user authentication sessions, including login, logout, and token refresh.
  """

  alias Auth.{User, Session, AuditLog, Repo}
  alias Plug.Crypto
  require Logger

  @max_failed_attempts 5
  @lockout_minutes 15
  @session_ttl_hours 8

  def login(email, password) when is_binary(email) and is_binary(password) do
    email_normalized = String.downcase(String.trim(email))

    case Repo.get_by(User, email: email_normalized) do
      nil ->
        Logger.warning("Login attempt for unknown email: #{email_normalized}")
        {:error, :invalid_credentials}

      %User{} = user ->
        # --- Check lockout ---
        lockout_threshold = DateTime.add(DateTime.utc_now(), -@lockout_minutes * 60, :second)

        if user.failed_attempts >= @max_failed_attempts and
             DateTime.compare(user.last_failed_at, lockout_threshold) == :gt do
          remaining =
            DateTime.diff(
              DateTime.add(user.last_failed_at, @lockout_minutes * 60, :second),
              DateTime.utc_now(),
              :second
            )

          Logger.warning("Account locked for #{email_normalized}, #{remaining}s remaining")
          {:error, {:account_locked, remaining}}
        else
          # --- Verify password ---
          if Crypto.secure_compare(
               Bcrypt.hash_pwd_salt(password),
               user.password_hash
             ) do
            # --- Reset failed attempts and update last_login ---
            user
            |> User.changeset(%{
              failed_attempts: 0,
              last_failed_at: nil,
              last_login_at: DateTime.utc_now()
            })
            |> Repo.update()

            # --- Generate session token ---
            token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

            expires_at =
              DateTime.utc_now()
              |> DateTime.add(@session_ttl_hours * 3600, :second)
              |> DateTime.truncate(:second)

            session_attrs = %{
              user_id: user.id,
              token: token,
              expires_at: expires_at,
              ip_address: nil,
              user_agent: nil
            }

            case Repo.insert(Session.changeset(%Session{}, session_attrs)) do
              {:ok, session} ->
                AuditLog.record(%{
                  user_id: user.id,
                  action: "login_success",
                  metadata: %{session_id: session.id}
                })

                Logger.info("User #{user.id} logged in successfully")
                {:ok, %{token: token, expires_at: expires_at, user: user}}

              {:error, changeset} ->
                Logger.error("Session insert failed for user #{user.id}: #{inspect(changeset.errors)}")
                {:error, :session_creation_failed}
            end
          else
            # --- Record failed attempt ---
            user
            |> User.changeset(%{
              failed_attempts: (user.failed_attempts || 0) + 1,
              last_failed_at: DateTime.utc_now()
            })
            |> Repo.update()

            AuditLog.record(%{
              user_id: user.id,
              action: "login_failure",
              metadata: %{reason: "bad_password"}
            })

            Logger.warning("Failed login for user #{user.id}")
            {:error, :invalid_credentials}
          end
        end
    end
  end

  def logout(token) when is_binary(token) do
    case Repo.get_by(Session, token: token) do
      nil     -> {:error, :not_found}
      session -> Repo.delete(session)
    end
  end
end
```
