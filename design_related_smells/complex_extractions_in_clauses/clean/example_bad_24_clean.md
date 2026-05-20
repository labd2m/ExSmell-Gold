```elixir
defmodule Accounts.LoginHandler do
  @moduledoc """
  Handles login attempt processing including lockout logic,
  MFA routing, and session creation for the user management system.
  """

  alias Accounts.{LoginAttempt, Session, MFA, AuditLog}
  alias Accounts.{LockoutPolicy, SecurityAlert, UserRepo}

  @max_failed_attempts 5
  @soft_lock_threshold 3

  # `last_ip` are pulled from the struct in every single clause head, but none
  # of them appear in the guard expressions or structural pattern matching.
  # Only `status` (matched by value) and `failed_attempts` (used in guards)
  # are responsible for clause dispatch. The extra extractions make it
  # unnecessarily difficult to identify what controls the branching logic.

  def handle_login(%LoginAttempt{
        status: :success,
        failed_attempts: failed_attempts,
        email: email,
        user_id: user_id,
        mfa_enabled: mfa_enabled,
        last_ip: last_ip
      })
      when failed_attempts == 0 do
    AuditLog.record(user_id, email, :login_success, last_ip)

    if mfa_enabled do
      token = MFA.issue_challenge(user_id)
      {:mfa_required, token}
    else
      session = Session.create(user_id, last_ip)
      UserRepo.reset_failed_attempts(user_id)
      {:ok, session}
    end
  end

  def handle_login(%LoginAttempt{
        status: :success,
        failed_attempts: failed_attempts,
        email: email,
        user_id: user_id,
        mfa_enabled: mfa_enabled,
        last_ip: last_ip
      })
      when failed_attempts > 0 and failed_attempts < @soft_lock_threshold do
    AuditLog.record(user_id, email, :login_success_after_failures, last_ip)
    SecurityAlert.notify_suspicious_login(email, last_ip, failed_attempts)

    if mfa_enabled do
      token = MFA.issue_challenge(user_id)
      {:mfa_required, token}
    else
      session = Session.create(user_id, last_ip)
      UserRepo.reset_failed_attempts(user_id)
      {:ok, session}
    end
  end

  def handle_login(%LoginAttempt{
        status: :failed,
        failed_attempts: failed_attempts,
        email: email,
        user_id: user_id,
        mfa_enabled: _mfa_enabled,
        last_ip: last_ip
      })
      when failed_attempts < @soft_lock_threshold do
    new_count = failed_attempts + 1
    UserRepo.increment_failed_attempts(user_id)
    AuditLog.record(user_id, email, :login_failed, last_ip)
    {:error, :invalid_credentials, new_count}
  end

  def handle_login(%LoginAttempt{
        status: :failed,
        failed_attempts: failed_attempts,
        email: email,
        user_id: user_id,
        mfa_enabled: _mfa_enabled,
        last_ip: last_ip
      })
      when failed_attempts >= @soft_lock_threshold and failed_attempts < @max_failed_attempts do
    UserRepo.increment_failed_attempts(user_id)
    AuditLog.record(user_id, email, :login_soft_locked, last_ip)
    SecurityAlert.notify_soft_lock(email, last_ip)
    {:error, :account_soft_locked}
  end

  def handle_login(%LoginAttempt{
        status: :failed,
        failed_attempts: failed_attempts,
        email: email,
        user_id: user_id,
        mfa_enabled: _mfa_enabled,
        last_ip: last_ip
      })
      when failed_attempts >= @max_failed_attempts do
    LockoutPolicy.hard_lock(user_id)
    AuditLog.record(user_id, email, :account_locked, last_ip)
    SecurityAlert.notify_hard_lock(email, last_ip, failed_attempts)
    {:error, :account_locked}
  end


  def handle_login(%LoginAttempt{status: status}) do
    {:error, {:unknown_status, status}}
  end
end
```
