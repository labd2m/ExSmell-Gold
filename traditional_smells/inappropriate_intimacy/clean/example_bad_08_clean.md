```elixir
defmodule MyApp.Auth.SessionManager do
  @moduledoc """
  Manages creation, validation, and revocation of authenticated sessions.
  Sessions are stored server-side and identified by a signed token.
  """

  alias MyApp.Accounts.{User, Role}
  alias MyApp.Auth.TokenStore
  alias MyApp.Crypto

  @session_ttl_seconds 86_400 * 7
  @max_failed_attempts 5

  def create(email, password) do
    user = User.fetch_by_email(email)

    cond do
      is_nil(user) ->
        {:error, :invalid_credentials}

      not is_nil(user.locked_at) ->
        {:error, :account_locked}

      not Crypto.verify(password, user.hashed_password) ->
        record_failed_attempt(user.id)
        {:error, :invalid_credentials}

      true ->
        role        = Role.primary_for(user)
        permissions = role.permissions
        scope       = role.scope

        session = build_session(user, permissions, scope)
        TokenStore.store(session)
        {:ok, session}
    end
  end

  def validate(token) do
    case TokenStore.fetch(token) do
      nil ->
        {:error, :invalid_session}

      session when session.expires_at < DateTime.utc_now() ->
        TokenStore.revoke(token)
        {:error, :session_expired}

      session ->
        {:ok, session}
    end
  end

  def revoke(token) do
    case TokenStore.fetch(token) do
      nil     -> {:error, :not_found}
      _session -> TokenStore.revoke(token)
    end
  end

  def revoke_all_for_user(user_id) do
    TokenStore.revoke_by_user(user_id)
  end

  def refresh(token) do
    case validate(token) do
      {:ok, session} ->
        revoke(token)
        refreshed = %{session |
          token:      generate_token(),
          expires_at: new_expiry()
        }
        TokenStore.store(refreshed)
        {:ok, refreshed}

      error ->
        error
    end
  end


  defp build_session(user, permissions, scope) do
    %{
      token:       generate_token(),
      user_id:     user.id,
      email:       user.email,
      permissions: permissions,
      scope:       scope,
      created_at:  DateTime.utc_now(),
      expires_at:  new_expiry()
    }
  end

  defp record_failed_attempt(user_id) do
    key = "failed:#{user_id}"
    count = :ets.update_counter(:auth_counters, key, {2, 1}, {key, 0})
    if count >= @max_failed_attempts do
      User.lock(user_id)
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp new_expiry do
    DateTime.utc_now() |> DateTime.add(@session_ttl_seconds, :second)
  end
end
```
