# example_bad_17_clean

```elixir
defmodule UserManagement.EmailChangeHandler do
  @moduledoc """
  Orchestrates the email address change workflow for authenticated users,
  coordinating with the identity service and enforcing domain and rate policies.
  """

  alias UserManagement.IdentityServiceClient
  alias UserManagement.UserStore
  alias UserManagement.DomainBlacklist
  alias UserManagement.ChangeCooldownTracker
  alias UserManagement.VerificationLog
  alias Notifications.EmailDispatcher
  alias UserManagement.AuditLogger

  @cooldown_hours 24
  @rate_limit_window_minutes 60
  @verification_ttl_hours 48

  def request_email_change(user_id, new_email, requester_ip) do
    with {:ok, user} <- UserStore.fetch(user_id),
         :ok <- assert_different_email(user.email, new_email),
         {:ok, result} <- handle_change_response(user, new_email, requester_ip),
         :ok <- VerificationLog.record(user_id, new_email, result) do
      {:ok, result}
    end
  end

  defp handle_change_response(user, new_email, requester_ip) do
    case IdentityServiceClient.request_email_change(user.identity_ref, %{new_email: new_email, ip: requester_ip}) do
      {:ok, %{status: "verification_sent", verification_id: vid, expires_at: exp}} ->
        UserStore.set_pending_email(user.id, new_email, vid)
        EmailDispatcher.send_email_verification(new_email, vid, exp)
        AuditLogger.log(:email_change_requested, user.id, %{new_email: new_email, vid: vid})
        {:ok, %{status: :verification_sent, verification_id: vid, expires_at: exp}}

      {:ok, %{status: "already_verified", verified_at: ts}} ->
        UserStore.confirm_email_change(user.id, new_email)
        AuditLogger.log(:email_already_verified, user.id, %{new_email: new_email, at: ts})
        {:ok, %{status: :already_verified, verified_at: ts}}

      {:ok, %{status: "failed", reason: "email_taken", normalized_email: norm}} ->
        {:error, {:email_taken, norm}}

      {:ok, %{status: "failed", reason: "disposable_domain", domain: domain}} ->
        AuditLogger.log(:disposable_domain_rejected, user.id, %{domain: domain, ip: requester_ip})
        {:error, {:disposable_domain, domain}}

      {:ok, %{status: "failed", reason: "domain_blacklisted", domain: domain, list_id: lid}} ->
        DomainBlacklist.flag(user.id, domain, %{list_id: lid, ip: requester_ip})
        AuditLogger.log(:blacklisted_domain_attempt, user.id, %{domain: domain, list_id: lid})
        {:error, {:domain_blacklisted, domain}}

      {:ok, %{status: "failed", reason: "mx_invalid", domain: domain}} ->
        AuditLogger.log(:mx_invalid, user.id, %{domain: domain})
        {:error, {:mx_invalid, domain}}

      {:ok, %{status: "failed", reason: "rate_limited", retry_after: secs}} ->
        AuditLogger.log(:email_change_rate_limited, user.id, %{retry_after: secs, ip: requester_ip})
        {:error, {:rate_limited, secs}}

      {:ok, %{status: "failed", reason: "cooldown_active", cooldown_until: until}} ->
        ChangeCooldownTracker.record(user.id, until)
        {:error, {:cooldown_active, until}}

      {:ok, %{status: "failed", reason: other}} ->
        AuditLogger.log(:email_change_unknown_failure, user.id, %{reason: other})
        {:error, {:email_change_failed, other}}

      {:error, %{reason: :timeout}} ->
        {:error, :identity_service_timeout}

      {:error, reason} ->
        AuditLogger.log(:identity_service_error, user.id, %{reason: reason})
        {:error, :identity_service_error}
    end
  end

  defp assert_different_email(current, new) when current != new, do: :ok
  defp assert_different_email(same, same), do: {:error, :email_unchanged}
end
```
