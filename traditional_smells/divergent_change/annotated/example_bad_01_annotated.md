# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `UserManager` module |
| **Affected functions** | `authenticate/2`, `issue_token/1`, `revoke_token/1` (auth reason) and `update_profile/2`, `change_email/2`, `upload_avatar/2` (profile reason) and `send_welcome_email/1`, `send_password_reset/1` (notification reason) |
| **Explanation** | The `UserManager` module bundles three unrelated responsibilities: authentication/token lifecycle, user profile management, and transactional email notifications. Each of these concerns has independent reasons to change (e.g., switching auth strategy, changing profile validation rules, or swapping email providers), making this a textbook Divergent Change. |

```elixir
defmodule MyApp.UserManager do
  @moduledoc """
  Handles all user-related operations within the platform.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Mailer
  alias MyApp.TokenStore

  import Ecto.Query, warn: false
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module has at least three unrelated
  # reasons to change: (1) authentication and token policies, (2) profile data
  # management, and (3) email notification content and delivery. Each axis of
  # change is independent and should live in its own cohesive module.

  ## ── Authentication & Token Management ───────────────────────────────────────

  @doc """
  Authenticates a user by email and password. Returns `{:ok, user}` on
  success or `{:error, reason}` on failure.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | {:error, atom()}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      %User{active: false} ->
        {:error, :account_disabled}

      user ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Issues a signed JWT for the given user, persisting the jti to the token
  store so it can be individually revoked.
  """
  @spec issue_token(User.t()) :: {:ok, String.t()} | {:error, term()}
  def issue_token(%User{id: user_id, role: role}) do
    jti = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    expires_at = DateTime.utc_now() |> DateTime.add(86_400, :second)

    claims = %{"sub" => user_id, "role" => role, "jti" => jti, "exp" => DateTime.to_unix(expires_at)}

    with {:ok, token} <- MyApp.JWT.sign(claims),
         :ok <- TokenStore.persist(jti, user_id, expires_at) do
      {:ok, token}
    end
  end

  @doc """
  Revokes a previously issued token so it can no longer be used.
  """
  @spec revoke_token(String.t()) :: :ok | {:error, :not_found}
  def revoke_token(jti) do
    TokenStore.revoke(jti)
  end

  ## ── Profile Management ───────────────────────────────────────────────────────

  @doc """
  Updates mutable profile fields for a user.
  """
  @spec update_profile(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Changes the user's email address. The new address must be unique and will
  require re-verification before it becomes active.
  """
  @spec change_email(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def change_email(%User{} = user, new_email) do
    changeset = User.email_changeset(user, %{email: new_email, email_verified: false})

    with {:ok, updated_user} <- Repo.update(changeset) do
      send_email_verification(updated_user)
      {:ok, updated_user}
    end
  end

  @doc """
  Stores the avatar URL after upload has been handled by the caller.
  """
  @spec upload_avatar(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def upload_avatar(%User{} = user, avatar_url) when is_binary(avatar_url) do
    user
    |> User.changeset(%{avatar_url: avatar_url})
    |> Repo.update()
  end

  ## ── Email Notifications ──────────────────────────────────────────────────────

  @doc """
  Sends the onboarding welcome email to a newly registered user.
  """
  @spec send_welcome_email(User.t()) :: {:ok, term()} | {:error, term()}
  def send_welcome_email(%User{email: email, name: name}) do
    Logger.info("Sending welcome email to #{email}")

    Mailer.deliver(
      to: email,
      subject: "Welcome to MyApp, #{name}!",
      template: "welcome",
      assigns: %{name: name}
    )
  end

  @doc """
  Sends a password-reset link to the user's registered email address.
  """
  @spec send_password_reset(User.t()) :: {:ok, term()} | {:error, term()}
  def send_password_reset(%User{email: email, id: user_id}) do
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "password_reset", user_id)
    reset_url = MyAppWeb.Router.Helpers.password_reset_url(MyAppWeb.Endpoint, :edit, token)

    Mailer.deliver(
      to: email,
      subject: "Reset your MyApp password",
      template: "password_reset",
      assigns: %{reset_url: reset_url}
    )
  end

  defp send_email_verification(%User{email: email, id: user_id}) do
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "email_verify", user_id)
    verify_url = MyAppWeb.Router.Helpers.email_verify_url(MyAppWeb.Endpoint, :verify, token)

    Mailer.deliver(
      to: email,
      subject: "Please verify your new email address",
      template: "email_verification",
      assigns: %{verify_url: verify_url}
    )
  end

  # VALIDATION: SMELL END
end
```
