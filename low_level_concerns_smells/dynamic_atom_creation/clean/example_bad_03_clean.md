```elixir
defmodule MyApp.Auth.SessionManager do
  @moduledoc """
  Builds, validates, and invalidates user sessions.
  Sessions are stored in an ETS-backed cache with a configurable TTL.
  """

  require Logger

  alias MyApp.Accounts.User
  alias MyApp.Auth.{Token, SessionStore}

  @session_ttl_seconds 3_600
  @max_sessions_per_user 5

  @doc """
  Creates a new session for the given user record.
  Returns `{:ok, token}` where `token` is a signed JWT string.
  """
  @spec create(User.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(%User{} = user, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @session_ttl_seconds)

    with :ok <- check_session_limit(user.id),
         {:ok, session} <- build_session(user, ttl),
         {:ok, token} <- Token.sign(session),
         :ok <- SessionStore.put(session.id, session, ttl) do
      Logger.info("Session created", user_id: user.id, session_id: session.id)
      {:ok, token}
    end
  end

  @doc """
  Validates a raw token string and returns the decoded session map if valid.
  """
  @spec validate(String.t()) :: {:ok, map()} | {:error, term()}
  def validate(raw_token) when is_binary(raw_token) do
    with {:ok, claims} <- Token.verify(raw_token),
         {:ok, session} <- SessionStore.get(claims["session_id"]),
         :ok <- check_expiry(session) do
      {:ok, session}
    end
  end

  @doc """
  Explicitly invalidates a session by ID.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(session_id) when is_binary(session_id) do
    SessionStore.delete(session_id)
    Logger.info("Session invalidated", session_id: session_id)
    :ok
  end

  defp build_session(%User{id: user_id, email: email, role: role}, ttl) do
    session = %{
      id: MyApp.UUID.generate(),
      user_id: user_id,
      email: email,
      role: String.to_atom(role),
      expires_at: DateTime.add(DateTime.utc_now(), ttl, :second),
      created_at: DateTime.utc_now()
    }

    {:ok, session}
  end

  defp check_session_limit(user_id) do
    case SessionStore.count(user_id) do
      count when count >= @max_sessions_per_user ->
        {:error, :session_limit_reached}

      _ ->
        :ok
    end
  end

  defp check_expiry(%{expires_at: expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      :ok
    else
      {:error, :session_expired}
    end
  end
end
```
