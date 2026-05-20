```elixir
defmodule Auth.AccessControl do
  @moduledoc """
  Role-based access control for the authentication subsystem.
  Determines whether a user may perform a given action based
  on their role, account status, and assigned permissions.
  """

  alias Auth.{User, ActionLog, PermissionSet}

  @admin_actions ~w(delete_user reset_password export_data manage_roles)a
  @moderator_actions ~w(suspend_user review_content flag_content)a


  def authorize_action(
        %User{
          role: :admin,
          active: true,
          email: email,
          last_login: last_login,
          permissions: permissions
        },
        action
      )
      when is_atom(action) do
    if action in @admin_actions or PermissionSet.includes?(permissions, action) do
      ActionLog.record(email, action, :granted)
      log_sensitive_access(email, last_login, action)
      {:ok, :granted}
    else
      ActionLog.record(email, action, :denied)
      {:error, :action_not_permitted}
    end
  end

  def authorize_action(
        %User{
          role: :moderator,
          active: true,
          email: email,
          last_login: last_login,
          permissions: permissions
        },
        action
      )
      when is_atom(action) do
    if action in @moderator_actions or PermissionSet.includes?(permissions, action) do
      ActionLog.record(email, action, :granted)
      log_sensitive_access(email, last_login, action)
      {:ok, :granted}
    else
      ActionLog.record(email, action, :denied)
      {:error, :action_not_permitted}
    end
  end

  def authorize_action(
        %User{
          role: :viewer,
          active: true,
          email: email,
          last_login: last_login,
          permissions: permissions
        },
        action
      )
      when is_atom(action) do
    cond do
      PermissionSet.includes?(permissions, action) ->
        ActionLog.record(email, action, :granted)
        log_sensitive_access(email, last_login, action)
        {:ok, :granted}

      true ->
        ActionLog.record(email, action, :denied)
        {:error, :insufficient_role}
    end
  end

  def authorize_action(
        %User{
          role: _role,
          active: false,
          email: email,
          last_login: last_login,
          permissions: _permissions
        },
        action
      ) do
    ActionLog.record(email, action, :denied_inactive)
    Logger.warning("Inactive user #{email} attempted #{action}. Last login: #{last_login}")
    {:error, :account_inactive}
  end


  def authorize_action(%User{}, _action) do
    {:error, :unknown_role}
  end

  defp log_sensitive_access(email, last_login, action) do
    if action in @admin_actions do
      Logger.info("Sensitive action #{action} by #{email} (last login: #{last_login})")
    end
  end
end
```
