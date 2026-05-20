```elixir
defmodule Auth.AccessController do
  alias Auth.{User, Policy, AuditLog}
  require Logger

  @moduledoc """
  Role-based access control for the authentication subsystem.
  Evaluates user roles and account state before granting permissions.
  """

  @max_failed_attempts 5

  def authorize_action(
        %User{
          id: id,
          email: email,
          role: role,
          department: department,
          failed_attempts: failed_attempts,
          last_login: last_login
        },
        action
      )
      when role in [:admin, :superadmin] and failed_attempts < @max_failed_attempts do
    Logger.info("Admin #{email} (#{department}) authorizing action: #{action}")

    AuditLog.record(%{
      user_id: id,
      email: email,
      action: action,
      department: department,
      last_login: last_login,
      result: :authorized,
      timestamp: DateTime.utc_now()
    })

    {:ok, Policy.build_permissions(role, department)}
  end

  def authorize_action(
        %User{
          id: id,
          email: email,
          role: role,
          department: department,
          failed_attempts: failed_attempts,
          last_login: last_login
        },
        action
      )
      when role == :manager and failed_attempts < @max_failed_attempts do
    Logger.info("Manager #{email} requesting #{action} in #{department}")
    permissions = Policy.build_permissions(role, department)

    if action in permissions.allowed_actions do
      AuditLog.record(%{
        user_id: id,
        email: email,
        action: action,
        department: department,
        last_login: last_login,
        result: :authorized,
        timestamp: DateTime.utc_now()
      })

      {:ok, permissions}
    else
      AuditLog.record(%{
        user_id: id,
        email: email,
        action: action,
        department: department,
        result: :forbidden,
        timestamp: DateTime.utc_now()
      })

      {:error, :forbidden}
    end
  end

  def authorize_action(
        %User{
          id: id,
          email: email,
          role: role,
          department: department,
          failed_attempts: failed_attempts,
          last_login: last_login
        },
        action
      )
      when role == :viewer and failed_attempts < @max_failed_attempts do
    Logger.info("Viewer #{email} requesting #{action}")

    if action in [:read, :list] do
      AuditLog.record(%{
        user_id: id,
        email: email,
        action: action,
        department: department,
        last_login: last_login,
        result: :authorized,
        timestamp: DateTime.utc_now()
      })

      {:ok, Policy.build_permissions(:viewer, department)}
    else
      {:error, :read_only}
    end
  end

  def authorize_action(
        %User{
          id: id,
          email: email,
          failed_attempts: failed_attempts
        },
        _action
      )
      when failed_attempts >= @max_failed_attempts do
    Logger.warn("Locked account access attempt by #{email}")

    AuditLog.record(%{
      user_id: id,
      email: email,
      result: :account_locked,
      timestamp: DateTime.utc_now()
    })

    {:error, :account_locked}
  end
end
```
