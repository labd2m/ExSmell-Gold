# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `SessionManager.session_ttl_seconds/1` and `SessionManager.api_rate_limit/1`
- **Affected functions:** `session_ttl_seconds/1`, `api_rate_limit/1`
- **Short explanation:** The same `case` branching over account type (`:trial`, `:personal`, `:business`, `:enterprise`) is duplicated in `session_ttl_seconds/1` and `api_rate_limit/1`. Any change to the set of account types requires updating both case blocks.

---

```elixir
defmodule SessionManager do
  @moduledoc """
  Manages user sessions, token issuance, and per-account-type
  security policies including session lifetimes and API rate limits
  for an authentication service.
  """

  alias SessionManager.{Session, User, TokenStore, AuditLog}

  @type account_type :: :trial | :personal | :business | :enterprise

  @spec create_session(User.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def create_session(%User{} = user, metadata \\ %{}) do
    ttl = session_ttl_seconds(user.account_type)
    token = generate_secure_token()
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

    session = %Session{
      user_id: user.id,
      token: token,
      account_type: user.account_type,
      expires_at: expires_at,
      metadata: metadata,
      created_at: DateTime.utc_now()
    }

    with :ok <- TokenStore.put(token, session, ttl: ttl),
         :ok <- AuditLog.record(:session_created, user.id, %{ip: metadata[:ip]}) do
      {:ok, session}
    end
  end

  @spec check_rate_limit(User.t(), String.t()) :: :ok | {:error, :rate_limited}
  def check_rate_limit(%User{} = user, endpoint) do
    limit = api_rate_limit(user.account_type)
    window_key = "rate:#{user.id}:#{endpoint}:#{current_minute()}"

    case TokenStore.increment(window_key, ttl: 60) do
      {:ok, count} when count <= limit -> :ok
      {:ok, _count} -> {:error, :rate_limited}
      {:error, _reason} -> :ok
    end
  end

  @spec invalidate_session(String.t()) :: :ok | {:error, :not_found}
  def invalidate_session(token) do
    case TokenStore.delete(token) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec extend_session(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def extend_session(%Session{} = session) do
    if session_expired?(session) do
      {:error, :session_expired}
    else
      ttl = session_ttl_seconds(session.account_type)
      new_expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
      updated = %{session | expires_at: new_expires_at}
      TokenStore.put(session.token, updated, ttl: ttl)
      {:ok, updated}
    end
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `account_type`
  # also appears in `api_rate_limit/1` below. Both enumerate :trial, :personal,
  # :business, :enterprise — adding a new type requires touching both.
  @spec session_ttl_seconds(account_type()) :: integer()
  def session_ttl_seconds(account_type) do
    case account_type do
      :trial      -> 3_600
      :personal   -> 86_400
      :business   -> 604_800
      :enterprise -> 2_592_000
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `account_type`
  # already appeared in `session_ttl_seconds/1` above. The four account type atoms
  # are fully repeated, making this pair of functions hard to keep consistent.
  @spec api_rate_limit(account_type()) :: integer()
  def api_rate_limit(account_type) do
    case account_type do
      :trial      -> 60
      :personal   -> 300
      :business   -> 1_000
      :enterprise -> 10_000
    end
  end
  # VALIDATION: SMELL END

  @spec session_expired?(Session.t()) :: boolean()
  defp session_expired?(%Session{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  @spec generate_secure_token() :: String.t()
  defp generate_secure_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @spec current_minute() :: integer()
  defp current_minute do
    DateTime.utc_now() |> DateTime.to_unix() |> div(60)
  end
end
```
