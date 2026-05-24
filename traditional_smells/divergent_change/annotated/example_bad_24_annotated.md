# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `UserManager` module (entire module)
- **Affected functions:** `authenticate/2`, `rotate_api_key/1`, `update_profile/2`, `change_avatar/2`, `send_welcome_email/1`, `send_password_reset/1`
- **Explanation:** The `UserManager` module bundles three unrelated responsibilities: authentication logic, profile management, and email notification dispatch. Each concern has its own independent reasons to change (e.g., adding OAuth providers, supporting new profile fields, or switching email providers), causing the module to be modified frequently and for unrelated reasons.

---

```elixir
defmodule MyApp.UserManager do
  @moduledoc """
  Handles user-related operations including authentication,
  profile management, and email notifications.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.User
  alias MyApp.Mailer
  import Ecto.Query, warn: false

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because this module has at least three unrelated
  # reasons to change: (1) authentication policies, (2) profile management rules,
  # and (3) email/notification delivery. Any of these concerns may evolve
  # independently, causing unrelated parts of this module to be modified.

  ## ── Authentication ──────────────────────────────────────────────────────────

  @doc """
  Authenticates a user by email and password.
  Returns `{:ok, user}` on success or `{:error, reason}` on failure.
  """
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      %User{locked_at: locked_at} = user when not is_nil(locked_at) ->
        {:error, :account_locked}

      user ->
        if Argon2.verify_pass(password, user.password_hash) do
          Repo.update!(User.changeset(user, %{last_signed_in_at: DateTime.utc_now(), failed_attempts: 0}))
          {:ok, user}
        else
          attempts = (user.failed_attempts || 0) + 1
          updates = if attempts >= 5,
            do: %{failed_attempts: attempts, locked_at: DateTime.utc_now()},
            else: %{failed_attempts: attempts}
          Repo.update!(User.changeset(user, updates))
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Rotates the API key for the given user, invalidating the previous one.
  """
  def rotate_api_key(%User{} = user) do
    new_key = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    user
    |> User.changeset(%{api_key: new_key, api_key_issued_at: DateTime.utc_now()})
    |> Repo.update()
  end

  ## ── Profile Management ──────────────────────────────────────────────────────

  @doc """
  Updates mutable profile fields for the given user.
  """
  def update_profile(%User{} = user, attrs) do
    allowed = [:display_name, :bio, :locale, :timezone, :phone_number]
    filtered = Map.take(attrs, allowed)

    user
    |> User.changeset(filtered)
    |> Repo.update()
  end

  @doc """
  Replaces the user's avatar with a new upload.
  Deletes the old avatar from object storage if one exists.
  """
  def change_avatar(%User{} = user, %Plug.Upload{} = upload) do
    with {:ok, key} <- MyApp.Storage.upload(upload, prefix: "avatars/#{user.id}"),
         {:ok, url} <- MyApp.Storage.public_url(key) do
      if user.avatar_key, do: MyApp.Storage.delete(user.avatar_key)

      user
      |> User.changeset(%{avatar_url: url, avatar_key: key})
      |> Repo.update()
    end
  end

  ## ── Email Notifications ─────────────────────────────────────────────────────

  @doc """
  Sends a welcome email to a newly registered user.
  """
  def send_welcome_email(%User{} = user) do
    user
    |> MyApp.Emails.welcome(user.email, user.display_name)
    |> Mailer.deliver_later()
  end

  @doc """
  Generates a password-reset token and emails it to the user.
  Token expires after 2 hours.
  """
  def send_password_reset(%User{} = user) do
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "password_reset", user.id)
    expires_at = DateTime.add(DateTime.utc_now(), 7_200, :second)

    Repo.update!(User.changeset(user, %{
      reset_token: token,
      reset_token_expires_at: expires_at
    }))

    user
    |> MyApp.Emails.password_reset(user.email, token)
    |> Mailer.deliver_later()
  end

  # VALIDATION: SMELL END
end
```
