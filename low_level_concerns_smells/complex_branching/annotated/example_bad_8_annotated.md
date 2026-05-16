# Code Smell: Complex branching

- **Smell name:** Complex branching
- **Expected smell location:** `verify_identity/2`, inside the `case` that handles all response variants from `IdentityProviderClient.verify/2`
- **Affected function(s):** `verify_identity/2`
- **Short explanation:** `verify_identity/2` encodes every possible response from the identity provider — verified, token expired, MFA required, account locked, email unverified, rate-limited, suspended, unknown status, and two network-level errors — inside a single `case` block. The cyclomatic complexity is very high; a bug or typo in any one clause can silently corrupt the handling of every other response type, and testing each path requires going through the same monolithic function.

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

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because every possible response variant from
  # `IdentityProviderClient.verify/2` is handled inside one `case` block in
  # a single function. Nine distinct branches — covering happy path, token
  # refresh, MFA challenge, account lock, unverified email, rate limiting,
  # suspension, unknown status, and two network-failure variants — are fused
  # together. This dramatically raises cyclomatic complexity, makes the function
  # long and hard to read, and means a typo in any one branch can break all
  # others if the function raises an exception rather than returning an error.
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
  # VALIDATION: SMELL END

  defp session_opts(result) do
    [mfa_verified: result.mfa_verified, duration_hours: @max_session_duration_hours]
  end
end
```
