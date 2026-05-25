# Annotated Example — Speculative Generality

## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** `create_session/3` in `Auth.SessionManager`
- **Affected function(s):** `create_session/3`
- **Short explanation:** `create_session/3` accepts an `expiry_format` parameter with a default of `:absolute`. The intent was to support both absolute expiry (a fixed future timestamp) and sliding expiry (reset on each activity). In practice, every call site uses `create_session/2`, never specifying a format. No caller ever passes `:sliding`, making the parameter and its branching logic dead speculative flexibility.

---

```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Manages authenticated user sessions: creation, validation, refresh, and revocation.

  Sessions are stored in the distributed session store with configurable
  TTLs. The session token is an opaque random reference; all session state
  is server-side.
  """

  require Logger

  alias Auth.{SessionStore, Account, ActivityLog}

  @session_ttl_seconds 86_400
  @sliding_window_seconds 3_600
  @token_bytes 32

  @spec create_session(String.t(), map()) ::
          {:ok, map()} | {:error, atom()}
  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because the `expiry_format` parameter with default 
  # `:absolute` was added speculatively to support `:sliding` window sessions that 
  # reset their TTL on each request. No call site in the codebase ever passes a 
  # second argument beyond `account_id` and `metadata`, so the `:sliding` branch 
  # and the `@sliding_window_seconds` module attribute are dead speculative code. 
  # Every session is created with `:absolute` expiry.
  def create_session(account_id, metadata, expiry_format \\ :absolute) do
    with {:ok, account} <- Account.fetch(account_id),
         :ok <- validate_account_active(account) do
      token = generate_token()

      expires_at =
        case expiry_format do
          :absolute ->
            DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

          :sliding ->
            DateTime.add(DateTime.utc_now(), @sliding_window_seconds, :second)
        end

      session = %{
        token: token,
        account_id: account_id,
        expires_at: expires_at,
        expiry_format: expiry_format,
        created_at: DateTime.utc_now(),
        metadata: metadata
      }

      case SessionStore.put(token, session) do
        :ok ->
          ActivityLog.record(account_id, :session_created, %{expiry_format: expiry_format})
          Logger.info("Session created account=#{account_id} format=#{expiry_format}")
          {:ok, %{token: token, expires_at: expires_at}}

        {:error, reason} ->
          Logger.error("Session store failed account=#{account_id}: #{inspect(reason)}")
          {:error, :session_store_error}
      end
    end
  end
  # VALIDATION: SMELL END

  @spec validate_session(String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_session(token) do
    case SessionStore.get(token) do
      {:ok, session} ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
          {:ok, session}
        else
          SessionStore.delete(token)
          {:error, :session_expired}
        end

      {:error, :not_found} ->
        {:error, :invalid_session}
    end
  end

  @spec revoke_session(String.t()) :: :ok | {:error, atom()}
  def revoke_session(token) do
    case SessionStore.delete(token) do
      :ok ->
        Logger.info("Session revoked token=#{String.slice(token, 0, 8)}...")
        :ok

      {:error, reason} ->
        Logger.warning("Session revoke failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec revoke_all_sessions(String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_all_sessions(account_id) do
    case SessionStore.delete_by_account(account_id) do
      {:ok, count} ->
        ActivityLog.record(account_id, :all_sessions_revoked, %{count: count})
        Logger.info("All sessions revoked account=#{account_id} count=#{count}")
        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_account_active(%{status: :active}), do: :ok
  defp validate_account_active(%{status: :suspended}), do: {:error, :account_suspended}
  defp validate_account_active(_), do: {:error, :account_inactive}

  defp generate_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

defmodule Auth.LoginController do
  alias Auth.{SessionManager, CredentialVerifier}

  def login(conn) do
    %{email: email, password: password} = conn.body_params

    with {:ok, account} <- CredentialVerifier.verify(email, password),
         {:ok, session} <- SessionManager.create_session(account.id, %{ip: conn.remote_ip}) do
      send_resp(conn, 200, Jason.encode!(%{token: session.token, expires_at: session.expires_at}))
    else
      {:error, :invalid_credentials} ->
        send_resp(conn, 401, Jason.encode!(%{error: "invalid_credentials"}))

      {:error, reason} ->
        send_resp(conn, 500, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp send_resp(conn, status, body), do: %{conn | status: status, resp_body: body}
end
```
