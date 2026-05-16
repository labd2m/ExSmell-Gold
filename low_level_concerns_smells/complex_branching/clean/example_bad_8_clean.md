# example_bad_8_clean

```elixir
defmodule Auth.IdentityVerifier do
  @moduledoc """
  Verifies user identity against an external identity provider,
  enforcing MFA, account status, and session-policy rules.
  """

  alias Auth.IdentityProviderClient
  alias Auth.SessionManager
  alias Auth.AuditLogger
  alias Auth.RateLimiter

  @max_session_duration_hours 8
  @mfa_grace_period_seconds 300

  def initiate_verification(user_id, credentials, opts \\ []) do
    device_id  = Keyword.get(opts, :device_id, "unknown")
    ip_address = Keyword.get(opts, :ip_address, "0.0.0.0")
    context    = %{user_id: user_id, device_id: device_id, ip: ip_address}

    with :ok <- RateLimiter.check(:identity_verification, user_id),
         {:ok, result} <- verify_identity(credentials, context),
         {:ok, session} <- SessionManager.create(user_id, result, @max_session_duration_hours),
         :ok <- AuditLogger.log(:identity_verified, user_id, %{device_id: device_id, ip: ip_address}) do
      {:ok,
       %{
         session_token: session.token,
         expires_at: session.expires_at,
         mfa_verified: result.mfa_verified
       }}
    end
  end

  defp verify_identity(credentials, context) do
    case IdentityProviderClient.verify(credentials, context) do
      {:ok, %{status: "verified", user: user, mfa_verified: mfa}} ->
        {:ok, %{user: user, mfa_verified: mfa, requires_mfa_step: false}}

      {:ok, %{status: "token_expired", refresh_token: refresh_token}} ->
        case IdentityProviderClient.refresh(refresh_token, context) do
          {:ok, new_creds} -> verify_identity(new_creds, context)
          {:error, _}      -> {:error, :session_expired}
        end

      {:ok, %{status: "mfa_required", challenge: challenge}} ->
        if Map.get(context, :mfa_token) do
          grace_expires = System.system_time(:second) + @mfa_grace_period_seconds
          {:ok,
           %{
             user: nil,
             mfa_verified: false,
             requires_mfa_step: true,
             challenge: challenge,
             grace_expires_at: grace_expires
           }}
        else
          {:error, {:mfa_required, challenge}}
        end

      {:ok, %{status: "account_locked", locked_until: until, reason: reason}} ->
        AuditLogger.log(:account_locked_attempt, context.user_id, %{until: until, reason: reason})
        {:error, {:account_locked, %{until: until, reason: reason}}}

      {:ok, %{status: "email_unverified", email: email}} ->
        {:error, {:email_unverified, email}}

      {:ok, %{status: "rate_limited", retry_after: retry_after}} ->
        RateLimiter.record_upstream_throttle(:identity_provider, context.user_id, retry_after)
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: "account_suspended", suspension_id: sid}} ->
        AuditLogger.log(:suspended_account_attempt, context.user_id, %{suspension_id: sid})
        {:error, {:account_suspended, sid}}

      {:ok, %{status: unknown_status}} ->
        AuditLogger.log(:unknown_idp_status, context.user_id, %{status: unknown_status})
        {:error, {:unexpected_status, unknown_status}}

      {:error, %{code: "network_timeout"}} ->
        {:error, :identity_provider_timeout}

      {:error, %{code: "service_unavailable", retry_after: retry}} ->
        {:error, {:identity_provider_unavailable, retry}}

      {:error, reason} ->
        AuditLogger.log(:idp_error, context.user_id, %{reason: reason})
        {:error, :identity_verification_failed}
    end
  end

  defp session_opts(result) do
    [mfa_verified: result.mfa_verified, duration_hours: @max_session_duration_hours]
  end
end
```
