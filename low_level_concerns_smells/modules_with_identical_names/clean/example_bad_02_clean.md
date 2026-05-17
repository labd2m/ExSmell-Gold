```elixir
# ── file: lib/auth/session.ex ─────────────────────────────────────────────────

defmodule Auth.Session do
  @moduledoc """
  Creates and validates user sessions for the authentication subsystem.
  Sessions are stored in an ETS-backed session store with configurable TTL.
  """

  alias Auth.{TokenSigner, User, SessionStore}

  @session_ttl_seconds 86_400
  @refresh_window_seconds 3_600

  @type session_id :: String.t()

  @type t :: %{
          id: session_id(),
          user_id: String.t(),
          roles: [String.t()],
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          ip_address: String.t(),
          user_agent: String.t()
        }

  @spec create(User.t(), map()) :: {:ok, t()} | {:error, atom()}
  def create(%User{id: user_id, roles: roles} = user, metadata) do
    with :ok <- check_account_active(user),
         :ok <- enforce_session_limit(user_id) do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, @session_ttl_seconds, :second)

      session = %{
        id: generate_session_id(),
        user_id: user_id,
        roles: roles,
        issued_at: now,
        expires_at: expires_at,
        ip_address: Map.get(metadata, :ip_address, "unknown"),
        user_agent: Map.get(metadata, :user_agent, "unknown")
      }

      token = TokenSigner.sign(session)
      SessionStore.put(session.id, session, @session_ttl_seconds)

      {:ok, Map.put(session, :token, token)}
    end
  end

  @spec validate(String.t()) :: {:ok, t()} | {:error, :expired | :invalid | :revoked}
  def validate(token) do
    with {:ok, claims} <- TokenSigner.verify(token),
         {:ok, session} <- SessionStore.get(claims["id"]),
         :ok <- check_expiry(session) do
      {:ok, session}
    else
      {:error, :not_found} -> {:error, :revoked}
      err -> err
    end
  end

  @spec refresh(t()) :: {:ok, t()} | {:error, atom()}
  def refresh(%{expires_at: expires_at} = session) do
    seconds_remaining = DateTime.diff(expires_at, DateTime.utc_now(), :second)

    if seconds_remaining <= @refresh_window_seconds and seconds_remaining > 0 do
      new_expires = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)
      refreshed = Map.put(session, :expires_at, new_expires)
      SessionStore.put(session.id, refreshed, @session_ttl_seconds)
      {:ok, refreshed}
    else
      {:error, :not_eligible_for_refresh}
    end
  end

  defp check_account_active(%User{active: true}), do: :ok
  defp check_account_active(_), do: {:error, :account_inactive}

  defp enforce_session_limit(user_id) do
    case SessionStore.count_for_user(user_id) do
      count when count >= 5 -> {:error, :too_many_sessions}
      _ -> :ok
    end
  end

  defp check_expiry(%{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end


# ── file: lib/auth/session_revocation.ex ─────────────────────────────────────

defmodule Auth.Session do
  @moduledoc """
  Handles revocation of user sessions, including single-session and
  full account logout flows. Used by security events and admin tooling.
  """

  alias Auth.{SessionStore, AuditLog, Notifier}

  @spec revoke(String.t(), keyword()) :: :ok | {:error, :not_found}
  def revoke(session_id, opts \\ []) do
    reason = Keyword.get(opts, :reason, :user_logout)
    notify = Keyword.get(opts, :notify, false)

    case SessionStore.delete(session_id) do
      {:ok, session} ->
        AuditLog.write(:session_revoked, %{
          session_id: session_id,
          user_id: session.user_id,
          reason: reason
        })

        if notify, do: Notifier.notify_logout(session.user_id)

        :ok

      {:error, :not_found} = err ->
        err
    end
  end

  @spec revoke_all_for_user(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def revoke_all_for_user(user_id, opts \\ []) do
    reason = Keyword.get(opts, :reason, :admin_action)

    sessions = SessionStore.list_for_user(user_id)

    Enum.each(sessions, fn session ->
      SessionStore.delete(session.id)

      AuditLog.write(:session_revoked, %{
        session_id: session.id,
        user_id: user_id,
        reason: reason
      })
    end)

    {:ok, length(sessions)}
  end

  @spec revoke_except(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_except(user_id, current_session_id) do
    sessions =
      user_id
      |> SessionStore.list_for_user()
      |> Enum.reject(&(&1.id == current_session_id))

    Enum.each(sessions, &SessionStore.delete(&1.id))

    {:ok, length(sessions)}
  end
end
```
