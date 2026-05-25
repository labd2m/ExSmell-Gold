# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `AccessControl.allowed_actions/1` and `AccessControl.default_redirect/1`
- **Affected functions:** `allowed_actions/1`, `default_redirect/1`
- **Short explanation:** The same `case` branching over user role (`:viewer`, `:editor`, `:manager`, `:admin`) is duplicated in both `allowed_actions/1` and `default_redirect/1`. Adding a new role forces parallel edits in both functions.

---

```elixir
defmodule AccessControl do
  @moduledoc """
  Centralises authorisation decisions for the web application.
  Determines what actions a given role may perform and where users
  should be redirected after login based on their role.
  """

  alias AccessControl.{Session, User}

  @type role :: :viewer | :editor | :manager | :admin

  @spec authorise(Session.t(), atom()) :: :ok | {:error, :forbidden}
  def authorise(%Session{user: user}, action) do
    if action in allowed_actions(user.role) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @spec post_login_path(User.t()) :: String.t()
  def post_login_path(%User{} = user) do
    cond do
      user.force_password_reset -> "/account/reset-password"
      user.onboarding_incomplete -> "/onboarding"
      true -> default_redirect(user.role)
    end
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `role`
  # also appears in `default_redirect/1` below. Both functions enumerate
  # :viewer, :editor, :manager, :admin — adding a new role requires changes in both.
  @spec allowed_actions(role()) :: [atom()]
  def allowed_actions(role) do
    case role do
      :viewer ->
        [:read_report, :export_report, :view_dashboard]

      :editor ->
        [:read_report, :export_report, :view_dashboard,
         :create_report, :update_report]

      :manager ->
        [:read_report, :export_report, :view_dashboard,
         :create_report, :update_report, :delete_report,
         :manage_team, :view_audit_log]

      :admin ->
        [:read_report, :export_report, :view_dashboard,
         :create_report, :update_report, :delete_report,
         :manage_team, :view_audit_log,
         :manage_users, :manage_billing, :manage_integrations]
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `role`
  # already appeared in `allowed_actions/1` above. The role atoms are fully
  # repeated here, requiring parallel updates whenever the role taxonomy changes.
  @spec default_redirect(role()) :: String.t()
  defp default_redirect(role) do
    case role do
      :viewer  -> "/dashboard"
      :editor  -> "/reports"
      :manager -> "/team"
      :admin   -> "/admin"
    end
  end
  # VALIDATION: SMELL END

  @spec can_impersonate?(User.t()) :: boolean()
  def can_impersonate?(%User{role: role}) do
    role == :admin
  end

  @spec enforce_mfa?(User.t()) :: boolean()
  def enforce_mfa?(%User{role: role}) do
    role in [:manager, :admin]
  end

  @spec audit_required?(atom()) :: boolean()
  def audit_required?(action) do
    action in [:delete_report, :manage_users, :manage_billing,
               :manage_integrations, :manage_team]
  end

  @spec build_permission_context(User.t()) :: map()
  def build_permission_context(%User{} = user) do
    actions = allowed_actions(user.role)

    %{
      role: user.role,
      actions: actions,
      can_manage_users: :manage_users in actions,
      can_manage_billing: :manage_billing in actions,
      requires_mfa: enforce_mfa?(user),
      can_impersonate: can_impersonate?(user)
    }
  end
end
```
