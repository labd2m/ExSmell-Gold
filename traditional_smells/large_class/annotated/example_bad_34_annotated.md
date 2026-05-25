# Annotated Example — Large Module

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `UserAccount` module
- **Affected functions:** `register/1`, `authenticate/2`, `update_profile/2`, `change_password/2`, `request_password_reset/1`, `reset_password/2`, `assign_role/2`, `suspend_account/1`, `delete_account/1`, `export_user_data/1`
- **Short explanation:** The `UserAccount` module merges authentication, profile management, access-control (roles), account lifecycle (suspension, deletion), and GDPR data export into one place. Each of these concerns represents a distinct subdomain that warrants its own module (e.g., `Accounts.Auth`, `Accounts.Profile`, `Accounts.Roles`, `Accounts.GDPR`). The resulting module is large, hard to navigate, and difficult to test in isolation.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because UserAccount bundles authentication,
# profile editing, password resets, role assignment, account suspension/deletion,
# and GDPR data export — five or more unrelated responsibilities — into a single
# module, making it far too large and lacking cohesion.
defmodule UserAccount do
  @moduledoc """
  Central module for all user-account operations: registration, authentication,
  profile management, role assignment, lifecycle actions, and data export.
  """

  require Logger
  alias Accounts.Repo
  alias Accounts.User
  alias Accounts.PasswordResetToken
  alias Accounts.AuditLog

  @bcrypt_rounds 12
  @reset_token_ttl_hours 2

  # --- Registration ---

  def register(attrs) do
    hashed = Bcrypt.hash_pwd_salt(attrs[:password], log_rounds: @bcrypt_rounds)

    changeset =
      User.changeset(%User{}, Map.merge(attrs, %{password_hash: hashed, status: :active}))

    case Repo.insert(changeset) do
      {:ok, user} ->
        AuditLog.record(:user_registered, user.id)
        {:ok, user}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # --- Authentication ---

  def authenticate(email, password) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      %User{status: :suspended} ->
        {:error, :account_suspended}

      user ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          token = generate_session_token(user)
          AuditLog.record(:login_success, user.id)
          {:ok, user, token}
        else
          AuditLog.record(:login_failure, user.id)
          {:error, :invalid_credentials}
        end
    end
  end

  defp generate_session_token(user) do
    Base.encode64(:crypto.strong_rand_bytes(32)) <>
      "." <>
      Integer.to_string(user.id)
  end

  # --- Profile management ---

  def update_profile(user, attrs) do
    allowed = Map.take(attrs, [:name, :phone, :timezone, :language, :avatar_url])

    user
    |> User.profile_changeset(allowed)
    |> Repo.update()
  end

  # --- Password management ---

  def change_password(user, %{current: current, new: new_pw, confirm: confirm}) do
    cond do
      not Bcrypt.verify_pass(current, user.password_hash) ->
        {:error, :wrong_current_password}

      new_pw != confirm ->
        {:error, :passwords_do_not_match}

      String.length(new_pw) < 8 ->
        {:error, :password_too_short}

      true ->
        hash = Bcrypt.hash_pwd_salt(new_pw, log_rounds: @bcrypt_rounds)
        user |> User.changeset(%{password_hash: hash}) |> Repo.update()
    end
  end

  def request_password_reset(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        :ok

      user ->
        raw_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        hashed = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
        expires_at = DateTime.add(DateTime.utc_now(), @reset_token_ttl_hours * 3600, :second)

        Repo.insert!(
          PasswordResetToken.changeset(%PasswordResetToken{}, %{
            user_id: user.id,
            token_hash: hashed,
            expires_at: expires_at
          })
        )

        Mailer.deliver(%{
          to: user.email,
          subject: "Reset your password",
          text_body: "Use this link to reset your password: https://app.example.com/reset/#{raw_token}"
        })

        :ok
    end
  end

  def reset_password(raw_token, new_password) do
    hashed = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)

    case Repo.get_by(PasswordResetToken, token_hash: hashed) do
      nil ->
        {:error, :invalid_token}

      %{expires_at: exp} when exp < DateTime.utc_now() ->
        {:error, :token_expired}

      token ->
        user = Repo.get!(User, token.user_id)
        hash = Bcrypt.hash_pwd_salt(new_password, log_rounds: @bcrypt_rounds)
        Repo.update!(User.changeset(user, %{password_hash: hash}))
        Repo.delete!(token)
        {:ok, user}
    end
  end

  # --- Role management ---

  def assign_role(user, role) when role in [:admin, :manager, :viewer] do
    user |> User.changeset(%{role: role}) |> Repo.update()
  end

  def assign_role(_user, role), do: {:error, {:unknown_role, role}}

  # --- Account lifecycle ---

  def suspend_account(user) do
    with {:ok, updated} <- Repo.update(User.changeset(user, %{status: :suspended})) do
      AuditLog.record(:account_suspended, user.id)
      Mailer.deliver(%{
        to: user.email,
        subject: "Your account has been suspended",
        text_body: "Contact support@example.com for assistance."
      })
      {:ok, updated}
    end
  end

  def delete_account(user) do
    Repo.transaction(fn ->
      Repo.delete_all(from t in PasswordResetToken, where: t.user_id == ^user.id)
      Repo.delete!(user)
      AuditLog.record(:account_deleted, user.id)
    end)
  end

  # --- GDPR data export ---

  def export_user_data(user) do
    profile = Map.take(user, [:id, :name, :email, :phone, :timezone, :inserted_at])
    audit_entries = AuditLog.for_user(user.id)

    %{
      exported_at: DateTime.utc_now(),
      profile: profile,
      audit_log: audit_entries
    }
  end
end
# VALIDATION: SMELL END
```
