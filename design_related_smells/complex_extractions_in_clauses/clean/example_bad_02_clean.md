```elixir
defmodule Auth.TokenValidator do
  @moduledoc """
  Validates access tokens and refresh tokens issued by the Auth service.
  Enforces expiry, scope checks, and revocation lookups.
  """

  require Logger

  alias Auth.{RevokedTokens, AuditLog, SessionStore, UserCache}

  @clock_skew_seconds 30

  def validate(%Auth.Token{
        token_id: token_id,
        user_id: user_id,
        scopes: scopes,
        issued_by: issued_by,
        token_type: :access,
        expires_at: expires_at
      })
      when expires_at > :os.system_time(:second) + @clock_skew_seconds do
    Logger.debug("[TokenValidator] Validating access token #{token_id} for user #{user_id}")

    with false <- RevokedTokens.revoked?(token_id),
         {:ok, session} <- SessionStore.fetch(user_id),
         true <- session.active?,
         :ok <- check_scopes(scopes, session.allowed_scopes) do
      AuditLog.record(:token_validated, %{
        token_id: token_id,
        user_id: user_id,
        issued_by: issued_by,
        scopes: scopes
      })

      {:ok, %{user_id: user_id, scopes: scopes, source: issued_by}}
    else
      true ->
        Logger.warning("[TokenValidator] Revoked access token used: #{token_id}")
        {:error, :revoked}

      {:error, :not_found} ->
        {:error, :session_not_found}

      false ->
        {:error, :session_inactive}

      {:error, :insufficient_scopes} ->
        Logger.warning("[TokenValidator] Insufficient scopes for token #{token_id}. " <>
                         "Requested: #{inspect(scopes)}")
        {:error, :insufficient_scopes}
    end
  end

  def validate(%Auth.Token{
        token_id: token_id,
        user_id: user_id,
        scopes: scopes,
        issued_by: issued_by,
        token_type: :refresh,
        expires_at: expires_at
      })
      when expires_at > :os.system_time(:second) do
    Logger.debug("[TokenValidator] Processing refresh token #{token_id} for user #{user_id}")

    with false <- RevokedTokens.revoked?(token_id),
         {:ok, user} <- UserCache.fetch(user_id),
         true <- user.account_active?,
         {:ok, new_token} <- Auth.TokenIssuer.issue_access(user_id, scopes, issued_by) do
      RevokedTokens.mark_used(token_id)

      AuditLog.record(:token_refreshed, %{
        old_token_id: token_id,
        new_token_id: new_token.token_id,
        user_id: user_id
      })

      {:ok, new_token}
    else
      true ->
        {:error, :refresh_token_revoked}

      {:error, :not_found} ->
        {:error, :user_not_found}

      false ->
        {:error, :account_suspended}

      error ->
        Logger.error("[TokenValidator] Failed to refresh token #{token_id}: #{inspect(error)}")
        {:error, :refresh_failed}
    end
  end

  def validate(%Auth.Token{
        token_id: token_id,
        user_id: user_id,
        scopes: _scopes,
        issued_by: issued_by,
        token_type: token_type,
        expires_at: expires_at
      })
      when expires_at <= :os.system_time(:second) do
    Logger.info(
      "[TokenValidator] Expired #{token_type} token #{token_id} for user #{user_id} " <>
        "(issued by #{issued_by}, expired at #{expires_at})"
    )

    AuditLog.record(:token_expired_attempted, %{
      token_id: token_id,
      user_id: user_id,
      token_type: token_type
    })

    {:error, :token_expired}
  end

  def validate(%Auth.Token{token_id: token_id, token_type: unknown}) do
    Logger.error("[TokenValidator] Unknown token type '#{unknown}' for token #{token_id}")
    {:error, :unknown_token_type}
  end

  # --- Private helpers ---

  defp check_scopes(requested, allowed) do
    if MapSet.subset?(MapSet.new(requested), MapSet.new(allowed)) do
      :ok
    else
      {:error, :insufficient_scopes}
    end
  end
end
```
