```elixir
defmodule MyApp.AuthService do
  @moduledoc """
  Provides authentication primitives for the MyApp platform,
  including password verification, token issuance, and session management.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Auth.{Token, Session}

  require Logger

  @token_ttl_seconds 86_400
  @max_failed_attempts 5


  # authenticate_user/2
  #
  # Verifies the provided plaintext password against the stored hashed password
  # for the user identified by `email`.
  #
  # Steps:
  #   1. Fetch the user record by email (case-insensitive).
  #   2. Check whether the account is locked due to too many failed attempts.
  #   3. Verify the password using Bcrypt.
  #   4. On success: reset failed-attempt counter and issue a new session token.
  #   5. On failure: increment failed-attempt counter and potentially lock account.
  #
  # Returns:
  #   {:ok, %{user: user, token: token_string}} on success
  #   {:error, :invalid_credentials} when email or password does not match
  #   {:error, :account_locked} when the account has been locked
  #   {:error, :user_not_found} when no account exists for the given email
  def authenticate_user(email, plaintext_password) do
    normalized_email = String.downcase(String.trim(email))

    case Repo.get_by(User, email: normalized_email) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :user_not_found}

      %User{locked: true} ->
        {:error, :account_locked}

      user ->
        verify_and_issue_token(user, plaintext_password)
    end
  end

  @doc """
  Invalidates a session token, effectively logging the user out.

  Returns `:ok` regardless of whether the token existed.
  """
  def logout(token_string) do
    Token
    |> Token.by_value(token_string)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Returns the `%User{}` associated with a valid, non-expired token,
  or `{:error, :unauthorized}` if the token is missing or expired.
  """
  def fetch_user_by_token(token_string) do
    cutoff = DateTime.add(DateTime.utc_now(), -@token_ttl_seconds, :second)

    case Repo.get_by(Token, value: token_string) do
      nil ->
        {:error, :unauthorized}

      %Token{inserted_at: inserted_at} when inserted_at < cutoff ->
        {:error, :unauthorized}

      %Token{user_id: user_id} ->
        {:ok, Repo.get!(User, user_id)}
    end
  end

  # --- Private helpers ---

  defp verify_and_issue_token(user, plaintext_password) do
    if Bcrypt.verify_pass(plaintext_password, user.password_hash) do
      reset_failed_attempts(user)
      token = issue_token(user)
      {:ok, %{user: user, token: token}}
    else
      increment_failed_attempts(user)
      {:error, :invalid_credentials}
    end
  end

  defp reset_failed_attempts(user) do
    user
    |> User.changeset(%{failed_attempts: 0, locked: false})
    |> Repo.update!()
  end

  defp increment_failed_attempts(user) do
    new_count = user.failed_attempts + 1
    locked = new_count >= @max_failed_attempts

    user
    |> User.changeset(%{failed_attempts: new_count, locked: locked})
    |> Repo.update!()

    if locked do
      Logger.warning("Account locked for user #{user.id} after #{new_count} failed attempts.")
    end
  end

  defp issue_token(user) do
    token_value = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    %Token{}
    |> Token.changeset(%{user_id: user.id, value: token_value})
    |> Repo.insert!()

    token_value
  end
end
```
