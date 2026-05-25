# Annotated Example — Large Module (Large Class)

| Field | Value |
|---|---|
| **Smell name** | Large Module (Large Class) |
| **Expected smell location** | `UserManager` module (entire module) |
| **Affected functions** | All functions across registration, authentication, password, roles, and audit concerns |
| **Short explanation** | `UserManager` handles user registration, credential verification, password reset workflows, role/permission assignment, and audit logging — five completely distinct responsibilities bundled into one module. |

```elixir
# VALIDATION: SMELL START - Large Module (Large Class)
# VALIDATION: This is a smell because UserManager conflates user registration,
# authentication, password reset, role management, and audit logging —
# all distinct concerns — into one non-cohesive module.
defmodule UserManager do
  @moduledoc """
  Central module for all user-related operations.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Auth.{User, PasswordReset, AuditLog, Role, UserRole}
  alias MyApp.Mailer
  alias Argon2

  @reset_token_ttl_hours 2
  @bcrypt_rounds 12

  # --- Registration ---

  def register(attrs) do
    with {:ok, validated} <- validate_registration(attrs),
         {:ok, hashed} <- hash_password(validated),
         {:ok, user} <- Repo.insert(User.changeset(%User{}, hashed)) do
      send_welcome_email(user)
      log_event(user.id, :registered, %{email: user.email})
      {:ok, user}
    end
  end

  defp validate_registration(%{email: email} = attrs) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil -> {:ok, attrs}
      _existing -> {:error, :email_already_taken}
    end
  end

  defp hash_password(%{password: pw} = attrs) do
    hashed = Argon2.hash_pwd_salt(pw, rounds: @bcrypt_rounds)
    {:ok, Map.merge(attrs, %{password_hash: hashed, password: nil})}
  end

  # --- Authentication ---

  def authenticate(email, password) do
    user = Repo.get_by(User, email: String.downcase(email), active: true)

    case user do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      %User{locked_until: locked} when not is_nil(locked) ->
        if DateTime.compare(locked, DateTime.utc_now()) == :gt do
          {:error, :account_locked}
        else
          verify_credentials(user, password)
        end

      user ->
        verify_credentials(user, password)
    end
  end

  defp verify_credentials(user, password) do
    if Argon2.verify_pass(password, user.password_hash) do
      reset_failed_attempts(user)
      log_event(user.id, :login_success, %{})
      {:ok, user}
    else
      increment_failed_attempts(user)
      log_event(user.id, :login_failure, %{})
      {:error, :invalid_credentials}
    end
  end

  defp reset_failed_attempts(user) do
    user |> User.changeset(%{failed_attempts: 0, locked_until: nil}) |> Repo.update()
  end

  defp increment_failed_attempts(%User{failed_attempts: n} = user) when n >= 4 do
    locked_until = DateTime.add(DateTime.utc_now(), 30 * 60, :second)
    user |> User.changeset(%{failed_attempts: n + 1, locked_until: locked_until}) |> Repo.update()
  end

  defp increment_failed_attempts(%User{failed_attempts: n} = user) do
    user |> User.changeset(%{failed_attempts: n + 1}) |> Repo.update()
  end

  # --- Password Reset ---

  def request_password_reset(email) do
    with %User{} = user <- Repo.get_by(User, email: String.downcase(email)),
         token <- :crypto.strong_rand_bytes(32) |> Base.url_encode64(),
         expires_at <- DateTime.add(DateTime.utc_now(), @reset_token_ttl_hours * 3600, :second),
         {:ok, _} <-
           Repo.insert(%PasswordReset{user_id: user.id, token: token, expires_at: expires_at}) do
      send_password_reset_email(user, token)
      :ok
    else
      nil -> :ok
      err -> err
    end
  end

  def reset_password(token, new_password) do
    now = DateTime.utc_now()

    case Repo.get_by(PasswordReset, token: token) do
      nil ->
        {:error, :invalid_token}

      %PasswordReset{expires_at: exp} when exp < now ->
        {:error, :token_expired}

      %PasswordReset{user_id: uid} = reset ->
        with {:ok, hashed} <- hash_password(%{password: new_password}),
             user <- Repo.get!(User, uid),
             {:ok, updated} <-
               user |> User.changeset(%{password_hash: hashed.password_hash}) |> Repo.update(),
             _ <- Repo.delete(reset) do
          log_event(uid, :password_reset, %{})
          {:ok, updated}
        end
    end
  end

  # --- Roles & Permissions ---

  def assign_role(user_id, role_name) do
    role = Repo.get_by!(Role, name: role_name)

    case Repo.get_by(UserRole, user_id: user_id, role_id: role.id) do
      nil ->
        Repo.insert(%UserRole{user_id: user_id, role_id: role.id})
        log_event(user_id, :role_assigned, %{role: role_name})

      _existing ->
        {:error, :role_already_assigned}
    end
  end

  def revoke_role(user_id, role_name) do
    role = Repo.get_by!(Role, name: role_name)

    case Repo.get_by(UserRole, user_id: user_id, role_id: role.id) do
      nil -> {:error, :role_not_found}
      ur -> Repo.delete(ur)
    end
  end

  def has_permission?(user_id, permission) do
    roles =
      Repo.all(
        from ur in UserRole,
          join: r in Role,
          on: ur.role_id == r.id,
          where: ur.user_id == ^user_id,
          select: r.permissions
      )

    roles
    |> List.flatten()
    |> Enum.member?(permission)
  end

  # --- Audit Logging ---

  defp log_event(user_id, event, metadata) do
    Repo.insert(%AuditLog{
      user_id: user_id,
      event: event,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    })
  end

  defp send_welcome_email(user) do
    Mailer.send(%{
      to: user.email,
      subject: "Welcome to MyApp!",
      body: "Hi #{user.name}, your account is ready."
    })
  end

  defp send_password_reset_email(user, token) do
    Mailer.send(%{
      to: user.email,
      subject: "Reset your password",
      body: "Use this link: https://myapp.com/reset?token=#{token}"
    })
  end
end
# VALIDATION: SMELL END
```
