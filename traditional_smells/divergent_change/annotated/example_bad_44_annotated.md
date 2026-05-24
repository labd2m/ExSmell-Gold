# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** The entire `UserManager` module
- **Affected function(s):** `authenticate/2`, `refresh_token/1`, `revoke_token/1`, `update_profile/2`, `change_email/2`, `change_password/2`, `send_welcome_email/1`, `send_password_reset_email/1`
- **Short explanation:** The `UserManager` module bundles three completely unrelated responsibilities — authentication/token lifecycle, user profile editing, and transactional email delivery. Each of these would evolve for independent reasons (e.g., adopting OAuth2 affects only auth functions; a new email provider affects only email functions; GDPR changes affect only profile functions), so the module will be modified repeatedly for unrelated reasons.

---

```elixir
defmodule MyApp.UserManager do
  @moduledoc """
  Handles user-related operations including authentication,
  profile management, and email notifications.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Accounts.Token
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module contains three unrelated clusters
  # VALIDATION: of functions. Authentication/token logic, profile mutation logic, and
  # VALIDATION: email delivery logic each have independent reasons to change, yet they
  # VALIDATION: all live in one module, making the module a target for unrelated edits.

  # ── Reason to modify (1): Authentication & token policies ──────────────────

  @token_ttl_seconds 3_600

  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        if Argon2.verify_pass(password, user.password_hash) do
          token = generate_token(user.id)
          {:ok, %{user: user, token: token, expires_in: @token_ttl_seconds}}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  def refresh_token(token_string) do
    with {:ok, token} <- fetch_valid_token(token_string),
         user <- Repo.get!(User, token.user_id),
         :ok <- revoke_token(token_string),
         new_token <- generate_token(user.id) do
      {:ok, %{user: user, token: new_token, expires_in: @token_ttl_seconds}}
    end
  end

  def revoke_token(token_string) do
    case Repo.get_by(Token, value: token_string) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token) && :ok
    end
  end

  defp generate_token(user_id) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), @token_ttl_seconds, :second)

    %Token{}
    |> Token.changeset(%{value: raw, user_id: user_id, expires_at: expires_at})
    |> Repo.insert!()
    |> Map.get(:value)
  end

  defp fetch_valid_token(token_string) do
    now = DateTime.utc_now()

    case Repo.get_by(Token, value: token_string) do
      nil -> {:error, :not_found}
      %Token{expires_at: exp} when exp < now -> {:error, :expired}
      token -> {:ok, token}
    end
  end

  # ── Reason to modify (2): User profile & credential management ─────────────

  def update_profile(user_id, attrs) do
    allowed = [:display_name, :avatar_url, :locale, :timezone]
    params = Map.take(attrs, allowed)

    user_id
    |> get_user!()
    |> User.profile_changeset(params)
    |> Repo.update()
  end

  def change_email(user_id, new_email) do
    normalized = String.downcase(new_email)

    existing =
      from(u in User, where: u.email == ^normalized and u.id != ^user_id)
      |> Repo.exists?()

    if existing do
      {:error, :email_taken}
    else
      user_id
      |> get_user!()
      |> User.email_changeset(%{email: normalized, email_verified: false})
      |> Repo.update()
    end
  end

  def change_password(user_id, current_password, new_password) do
    user = get_user!(user_id)

    if Argon2.verify_pass(current_password, user.password_hash) do
      user
      |> User.password_changeset(%{password: new_password})
      |> Repo.update()
    else
      {:error, :invalid_current_password}
    end
  end

  defp get_user!(user_id), do: Repo.get!(User, user_id)

  # ── Reason to modify (3): Transactional email delivery ─────────────────────

  @from_address "no-reply@myapp.io"

  def send_welcome_email(%User{email: email, display_name: name}) do
    body = """
    Hi #{name},

    Welcome to MyApp! Your account is ready to use.

    Cheers,
    The MyApp Team
    """

    dispatch_email(email, "Welcome to MyApp", body)
  end

  def send_password_reset_email(%User{email: email, display_name: name}, reset_token) do
    link = "https://myapp.io/reset-password?token=#{reset_token}"

    body = """
    Hi #{name},

    Click the link below to reset your password (valid for 30 minutes):

    #{link}

    If you did not request this, please ignore this email.

    Cheers,
    The MyApp Team
    """

    dispatch_email(email, "Reset your MyApp password", body)
  end

  defp dispatch_email(to, subject, body) do
    %{to: to, from: @from_address, subject: subject, text_body: body}
    |> MyApp.Mailer.deliver()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:email_delivery_failed, reason}}
    end
  end

  # VALIDATION: SMELL END
end
```
