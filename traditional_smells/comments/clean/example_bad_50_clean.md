```elixir
defmodule MyApp.Accounts.UserRegistration do
  @moduledoc false

  alias MyApp.Accounts.{User, EmailConfirmation, PasswordReset}
  alias MyApp.Repo
  alias MyApp.Mailer
  alias Ecto.Multi

  @confirmation_token_ttl_hours 24
  @reset_token_ttl_hours 2

  # Registers a new user account.
  #
  # Accepts a map of user attributes:
  #   :email       (required, string) — must be unique and valid format
  #   :password    (required, string) — minimum 12 characters
  #   :full_name   (required, string)
  #   :timezone    (optional, string, default "UTC")
  #   :locale      (optional, string, default "en")
  #
  # Side effects:
  #   - Inserts a new User record into the database.
  #   - Inserts an EmailConfirmation token record.
  #   - Sends a confirmation email via Mailer.
  #
  # Returns:
  #   {:ok, %User{}} on success.
  #   {:error, %Ecto.Changeset{}} if validation fails.
  #   {:error, :email_send_failed} if the confirmation email could not be sent.
  def register(attrs) when is_map(attrs) do
    token = generate_token()
    expires_at = DateTime.add(DateTime.utc_now(), @confirmation_token_ttl_hours * 3600, :second)

    result =
      Multi.new()
      |> Multi.insert(:user, User.registration_changeset(%User{}, attrs))
      |> Multi.insert(:confirmation, fn %{user: user} ->
        EmailConfirmation.changeset(%EmailConfirmation{}, %{
          user_id: user.id,
          token: token,
          expires_at: expires_at
        })
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{user: user}} ->
        case Mailer.send_confirmation(user, token) do
          :ok -> {:ok, user}
          {:error, _} -> {:error, :email_send_failed}
        end

      {:error, :user, changeset, _} ->
        {:error, changeset}

      {:error, _, _, _} ->
        {:error, :registration_failed}
    end
  end

  # Confirms a user's email address using a confirmation token.
  #
  # Parameters:
  #   user_id (integer) — the ID of the user whose email is being confirmed
  #   token   (string)  — the raw token sent in the confirmation email
  #
  # Marks the user as :active and deletes the confirmation record on success.
  #
  # Returns:
  #   {:ok, %User{status: :active}} when the token matches and is not expired.
  #   {:error, :invalid_token} when no matching token record is found.
  #   {:error, :token_expired} when the token TTL has elapsed.
  def confirm_email(user_id, token) when is_integer(user_id) and is_binary(token) do
    case Repo.get_by(EmailConfirmation, user_id: user_id, token: token) do
      nil ->
        {:error, :invalid_token}

      %EmailConfirmation{expires_at: exp} = confirmation ->
        if DateTime.compare(exp, DateTime.utc_now()) == :lt do
          {:error, :token_expired}
        else
          Multi.new()
          |> Multi.update(:user, fn _ ->
            user = Repo.get!(User, user_id)
            User.status_changeset(user, %{status: :active})
          end)
          |> Multi.delete(:confirmation, confirmation)
          |> Repo.transaction()
          |> case do
            {:ok, %{user: user}} -> {:ok, user}
            {:error, _, _, _} -> {:error, :confirmation_failed}
          end
        end
    end
  end

  # Initiates a password reset flow for the user with the given email.
  #
  # Looks up the user by email (case-insensitive). If found and active,
  # creates a PasswordReset record and sends a reset email.
  # If the email does not match any account, returns :ok anyway to
  # prevent email enumeration attacks.
  #
  # Returns:
  #   :ok in all cases (success, not found, or inactive).
  #   {:error, :send_failed} only when the email is found but delivery fails.
  def request_password_reset(email) when is_binary(email) do
    normalized = String.downcase(String.trim(email))

    case Repo.get_by(User, email: normalized, status: :active) do
      nil ->
        :ok

      user ->
        token = generate_token()
        expires_at = DateTime.add(DateTime.utc_now(), @reset_token_ttl_hours * 3600, :second)

        Repo.insert!(%PasswordReset{
          user_id: user.id,
          token: token,
          expires_at: expires_at
        })

        case Mailer.send_password_reset(user, token) do
          :ok -> :ok
          {:error, _} -> {:error, :send_failed}
        end
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
```
