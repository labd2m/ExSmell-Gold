```elixir
defmodule Auth.SessionGuard do
  @moduledoc """
  Evaluates incoming API requests against session state and role-based
  access policies before allowing the action to proceed.
  """

  alias Auth.{Session, AuditLog, RateLimiter, PolicyChecker}

  @valid_statuses [:active, :refreshed]
  @admin_rate_limit 500
  @user_rate_limit 100

  def authorize_action(
        %Session{
          role: role,
          status: status,
          user_id: user_id,
          expires_at: expires_at,
          ip_address: ip_address,
          session_token: session_token,
          device_id: device_id
        },
        %{type: action_type, resource: resource, params: params}
      )
      when role == :admin and status in @valid_statuses do
    :ok = RateLimiter.check!(user_id, @admin_rate_limit)

    AuditLog.record(:admin_action_attempted, %{
      user_id: user_id,
      role: role,
      action_type: action_type,
      resource: resource,
      ip_address: ip_address,
      device_id: device_id,
      session_token: session_token,
      expires_at: expires_at
    })

    case PolicyChecker.evaluate(:admin, action_type, resource, params) do
      :allow ->
        AuditLog.record(:admin_action_allowed, %{user_id: user_id, resource: resource})
        {:ok, :authorized}

      {:deny, reason} ->
        AuditLog.record(:admin_action_denied, %{
          user_id: user_id,
          resource: resource,
          reason: reason
        })
        {:error, {:unauthorized, reason}}
    end
  end

  def authorize_action(
        %Session{
          role: role,
          status: status,
          user_id: user_id,
          expires_at: expires_at,
          ip_address: ip_address,
          session_token: session_token,
          device_id: device_id
        },
        %{type: action_type, resource: resource, params: params}
      )
      when role in [:user, :moderator] and status in @valid_statuses do
    :ok = RateLimiter.check!(user_id, @user_rate_limit)

    AuditLog.record(:user_action_attempted, %{
      user_id: user_id,
      role: role,
      action_type: action_type,
      resource: resource,
      ip_address: ip_address,
      device_id: device_id,
      session_token: session_token,
      expires_at: expires_at
    })

    case PolicyChecker.evaluate(role, action_type, resource, params) do
      :allow ->
        {:ok, :authorized}

      {:deny, reason} ->
        AuditLog.record(:user_action_denied, %{
          user_id: user_id,
          resource: resource,
          reason: reason
        })
        {:error, {:unauthorized, reason}}
    end
  end

  def authorize_action(
        %Session{
          role: role,
          status: status,
          user_id: user_id,
          ip_address: ip_address,
          session_token: session_token
        },
        %{type: action_type}
      )
      when status == :expired do
    AuditLog.record(:expired_session_attempt, %{
      user_id: user_id,
      role: role,
      action_type: action_type,
      ip_address: ip_address,
      session_token: session_token
    })

    {:error, :session_expired}
  end

end
```
