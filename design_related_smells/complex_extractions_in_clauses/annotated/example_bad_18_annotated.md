# Annotated Example — Bad Code

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `authorize_action/2` function, multi-clause heads
- **Affected function(s):** `authorize_action/2`
- **Short explanation:** Each clause head destructures `%User{}` extracting `role`, `active`, `email`, `last_login`, and `permissions`. Only `role` and `active` are used for pattern/guard-based dispatch; `email`, `last_login`, and `permissions` are only referenced inside the function body. This obscures which extractions are doing guard work and which are just pulling values for later use.

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

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `email`, `last_login`, and `permissions`
  # are extracted in the clause head alongside `role` and `active`, but only
  # `role` and `active` influence which clause is selected. The other three
  # bindings exist purely for use inside the body, mixing guard-relevant and
  # body-only extractions in a way that grows confusing as clauses multiply.

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

  # VALIDATION: SMELL END

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
