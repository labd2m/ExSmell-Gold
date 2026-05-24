# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `SessionManager.create/2` function
- **Affected function(s):** `SessionManager.create/2`
- **Short explanation:** `SessionManager.create/2` calls `User.fetch_by_email/1` and `Role.primary_for/1` and then directly reads internal fields of those returned structs (`.hashed_password`, `.locked_at`, `.permissions`, `.scope`). This creates excessive coupling: the session creation logic knows internal details that should be encapsulated in the `User` and `Role` modules themselves.

---

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
    # VALIDATION: SMELL START - Inappropriate Intimacy
    # VALIDATION: This is a smell because create/2 fetches a User struct and directly
    # reads .hashed_password and .locked_at, and fetches a Role struct and directly reads
    # .permissions and .scope — internal details that should be exposed only through
    # dedicated query functions on User and Role respectively.
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
        # VALIDATION: SMELL END

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

  # --- Private helpers ---

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
