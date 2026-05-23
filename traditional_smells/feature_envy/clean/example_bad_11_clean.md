```elixir
defmodule Auth.SessionHandler do
  @moduledoc """
  Manages user sessions, tokens, and login flows.
  """

  alias Auth.{User, Session, AuditLog}
  require Logger

  @session_ttl_seconds 3_600
  @max_active_sessions 5

  def create_session(user_id, device_info) do
    with {:ok, user} <- User.fetch(user_id),
         :ok <- check_session_limit(user_id),
         {:ok, token} <- generate_token(user.id, device_info) do
      session = %Session{
        user_id: user.id,
        token: token,
        expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_seconds),
        device: device_info
      }

      Session.persist(session)
    end
  end

  def revoke_session(session_id) do
    Logger.info("Revoking session #{session_id}")
    Session.delete(session_id)
  end

  def refresh_session(session_id) do
    with {:ok, session} <- Session.fetch(session_id),
         :ok <- validate_not_expired(session) do
      new_expiry = DateTime.add(DateTime.utc_now(), @session_ttl_seconds)
      Session.update(session_id, %{expires_at: new_expiry})
    end
  end

  def list_active_sessions(user_id) do
    Session.list_by_user(user_id)
  end

  def terminate_all_sessions(user_id) do
    Logger.info("Terminating all sessions for user #{user_id}")
    Session.delete_all_by_user(user_id)
  end

  def audit_user_activity(user_id, action) do
    user = User.fetch!(user_id)

    roles = User.roles(user)
    permissions = User.permissions(user)
    mfa_enabled = User.mfa_enabled?(user)
    last_login = User.last_login(user)
    account_status = User.account_status(user)
    department = User.department(user)

    time_since_login =
      case last_login do
        nil -> nil
        dt -> DateTime.diff(DateTime.utc_now(), dt, :minute)
      end

    sensitive_action = action in [:delete_record, :export_data, :admin_override]

    risk_score =
      cond do
        account_status == :suspended -> 100
        sensitive_action and not mfa_enabled -> 75
        sensitive_action -> 40
        not mfa_enabled -> 20
        true -> 0
      end

    AuditLog.record(%{
      user_id: user.id,
      email: user.email,
      full_name: user.full_name,
      employee_id: user.employee_id,
      department: department,
      roles: roles,
      permissions: permissions,
      mfa_enabled: mfa_enabled,
      account_status: account_status,
      time_since_last_login_minutes: time_since_login,
      action: action,
      risk_score: risk_score,
      recorded_at: DateTime.utc_now()
    })
  end

  defp check_session_limit(user_id) do
    count = Session.count_active(user_id)
    if count >= @max_active_sessions, do: {:error, :too_many_sessions}, else: :ok
  end

  defp validate_not_expired(%Session{expires_at: exp}) do
    if DateTime.compare(exp, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp generate_token(user_id, device) do
    raw = "#{user_id}:#{device.id}:#{System.system_time(:nanosecond)}"
    {:ok, Base.encode64(:crypto.hash(:sha256, raw))}
  end
end
```
