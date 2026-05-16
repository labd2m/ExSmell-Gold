# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Auth.UserAuthenticator.authenticate/2`, around the `opts[:return]` branching
- **Affected function(s):** `authenticate/2`
- **Short explanation:** The function returns either `{:ok, %User{}}`, `{:ok, token_string}`, or `{:ok, %{user: %User{}, token: token_string, expires_at: datetime}}` depending on the `:return` option. The error paths are consistent, but the success shape changes drastically with the option, making pattern-matching on the result fragile for callers.

---

```elixir
defmodule Auth.UserAuthenticator do
  @moduledoc """
  Handles password-based authentication for user accounts.
  Supports multiple return shapes for different integration points.
  """

  alias Auth.Repo
  alias Auth.Schema.User
  alias Auth.Token

  require Logger

  @max_attempts 5
  @lockout_minutes 15

  @doc """
  Authenticates a user by email and password.

  ## Options

    * `:return` — Controls what is returned on success:
      - `:user` (default) — returns `{:ok, %User{}}`
      - `:token` — returns `{:ok, token_string}`
      - `:full` — returns `{:ok, %{user: %User{}, token: string, expires_at: DateTime.t()}}`

  ## Examples

      iex> authenticate("alice@example.com", "secret", return: :user)
      {:ok, %User{id: 1, email: "alice@example.com", ...}}

      iex> authenticate("alice@example.com", "secret", return: :token)
      {:ok, "eyJhbGciOiJIUzI1NiJ9..."}

      iex> authenticate("alice@example.com", "secret", return: :full)
      {:ok, %{user: %User{...}, token: "eyJ...", expires_at: ~U[2024-06-01 12:00:00Z]}}

      iex> authenticate("alice@example.com", "wrong_pass")
      {:error, :invalid_credentials}

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because the success return type changes
  # VALIDATION: completely based on the :return option: callers get either a
  # VALIDATION: %User{} struct, a plain token string, or a rich map — all wrapped
  # VALIDATION: in {:ok, ...}. This forces every call-site to know which option
  # VALIDATION: was passed before safely pattern-matching on the result.
  def authenticate(email, password, opts \\ []) do
    with {:ok, user} <- find_active_user(email),
         :ok <- check_lockout(user),
         :ok <- verify_password(user, password) do
      :ok = reset_failed_attempts(user)

      case Keyword.get(opts, :return, :user) do
        :token ->
          {:ok, token} = Token.generate(user.id)
          {:ok, token}

        :full ->
          {:ok, token} = Token.generate(user.id)
          expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
          {:ok, %{user: user, token: token, expires_at: expires_at}}

        _ ->
          {:ok, user}
      end
    end
  end
  # VALIDATION: SMELL END

  defp find_active_user(email) do
    case Repo.get_by(User, email: String.downcase(email), active: true) do
      nil -> {:error, :invalid_credentials}
      user -> {:ok, user}
    end
  end

  defp check_lockout(%User{failed_attempts: attempts, last_failed_at: last_failed_at}) do
    if attempts >= @max_attempts and not lockout_expired?(last_failed_at) do
      {:error, :account_locked}
    else
      :ok
    end
  end

  defp lockout_expired?(nil), do: true

  defp lockout_expired?(last_failed_at) do
    cutoff = DateTime.add(last_failed_at, @lockout_minutes * 60, :second)
    DateTime.compare(DateTime.utc_now(), cutoff) == :gt
  end

  defp verify_password(%User{password_hash: hash}, password) do
    if Bcrypt.verify_pass(password, hash) do
      :ok
    else
      {:error, :invalid_credentials}
    end
  end

  defp reset_failed_attempts(%User{} = user) do
    user
    |> User.changeset(%{failed_attempts: 0, last_failed_at: nil})
    |> Repo.update!()

    :ok
  end

  @doc """
  Increments the failed attempt counter for the given email, if the user exists.
  """
  def record_failed_attempt(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        :ok

      user ->
        user
        |> User.changeset(%{
          failed_attempts: user.failed_attempts + 1,
          last_failed_at: DateTime.utc_now()
        })
        |> Repo.update()

        Logger.warning("Failed login attempt for #{email}")
        :ok
    end
  end
end
```
