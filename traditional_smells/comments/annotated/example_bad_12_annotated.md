# Annotated Example

- **Smell name:** Comments
- **Expected smell location:** `AuthService.create_session/2`
- **Affected function(s):** `create_session/2`
- **Short explanation:** The function is documented using plain `#` comment blocks instead of `@doc`, bypassing Elixir's built-in documentation system entirely.

```elixir
defmodule MyApp.AuthService do
  @moduledoc """
  Handles user authentication, session management, and token lifecycle
  for the MyApp platform.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Auth.{Session, Token}

  require Logger

  @session_ttl_seconds 86_400
  @max_sessions_per_user 5

  @doc """
  Authenticates a user by email and password.

  Returns `{:ok, user}` on success or `{:error, :invalid_credentials}` if
  the credentials do not match.
  """
  def authenticate(email, password) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        if Argon2.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because create_session/2 is documented with plain # comments
  # rather than an @doc attribute, making the documentation invisible to ExDoc and IEx.h/1.

  # Creates a new authenticated session for the given user.
  #
  # - user: A %User{} struct representing the authenticated principal.
  # - metadata: A map of optional session metadata such as IP address and user-agent.
  #
  # On success returns {:ok, session} where session contains a signed token.
  # Enforces a maximum of @max_sessions_per_user concurrent sessions by evicting
  # the oldest session when the limit is exceeded.
  #
  # Returns {:error, reason} if session persistence fails.
  def create_session(%User{} = user, metadata \\ %{}) do
  # VALIDATION: SMELL END
    :ok = enforce_session_limit(user)

    token = Token.generate()
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

    attrs = %{
      user_id: user.id,
      token: token,
      ip_address: Map.get(metadata, :ip_address),
      user_agent: Map.get(metadata, :user_agent),
      expires_at: expires_at
    }

    case Session.changeset(%Session{}, attrs) |> Repo.insert() do
      {:ok, session} ->
        Logger.info("Session created", user_id: user.id, session_id: session.id)
        {:ok, session}

      {:error, changeset} ->
        Logger.error("Session creation failed", errors: changeset.errors)
        {:error, :session_creation_failed}
    end
  end

  @doc """
  Revokes an existing session by token string.

  Returns `:ok` if the session was found and deleted, or `{:error, :not_found}`
  if no matching session exists.
  """
  def revoke_session(token) do
    case Repo.get_by(Session, token: token) do
      nil ->
        {:error, :not_found}

      session ->
        Repo.delete(session)
        Logger.info("Session revoked", session_id: session.id)
        :ok
    end
  end

  @doc """
  Validates a session token and returns the associated user if the session
  is valid and has not expired.
  """
  def validate_token(token) do
    now = DateTime.utc_now()

    case Repo.get_by(Session, token: token) do
      nil ->
        {:error, :invalid_token}

      %Session{expires_at: exp} when exp < now ->
        {:error, :token_expired}

      session ->
        user = Repo.get!(User, session.user_id)
        {:ok, user, session}
    end
  end

  @doc """
  Extends the expiry of a valid session by another full TTL period.
  """
  def refresh_session(token) do
    with {:ok, _user, session} <- validate_token(token) do
      new_expiry = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

      session
      |> Session.changeset(%{expires_at: new_expiry})
      |> Repo.update()
    end
  end

  # --- Private helpers ---

  defp enforce_session_limit(%User{id: user_id}) do
    sessions =
      Session
      |> Repo.all(user_id: user_id)
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    if length(sessions) >= @max_sessions_per_user do
      oldest = List.first(sessions)
      Repo.delete(oldest)
      Logger.info("Evicted oldest session", user_id: user_id, session_id: oldest.id)
    end

    :ok
  end
end
```
