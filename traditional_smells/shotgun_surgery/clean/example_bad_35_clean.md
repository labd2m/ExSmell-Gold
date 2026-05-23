```elixir
defmodule IAM.AccessControl do
  @moduledoc """
  Enforces role-based access control by resolving allowed actions
  and user management permissions for each account role in the system.
  """


  @spec allowed_actions(atom()) :: [atom()]
  def allowed_actions(:admin) do
    [:read, :write, :delete, :manage_users, :manage_roles,
     :view_billing, :export_data, :configure_integrations]
  end

  def allowed_actions(:manager) do
    [:read, :write, :delete, :view_billing, :export_data]
  end

  def allowed_actions(:viewer) do
    [:read]
  end

  @spec can_manage_users?(atom()) :: boolean()
  def can_manage_users?(:admin),   do: true
  def can_manage_users?(:manager), do: false
  def can_manage_users?(:viewer),  do: false


  def authorize(user, action) do
    if action in allowed_actions(user.role) do
      :ok
    else
      {:error, {:forbidden, %{role: user.role, action: action}}}
    end
  end

  def check_permission(user, resource, action) do
    with :ok <- authorize(user, action),
         :ok <- check_resource_ownership(user, resource) do
      :ok
    end
  end

  defp check_resource_ownership(_user, _resource), do: :ok
end

defmodule IAM.DashboardConfig do
  @moduledoc """
  Resolves per-role dashboard defaults and visible navigation sections
  to personalise the UI experience for different account types.
  """


  @spec default_dashboard(atom()) :: String.t()
  def default_dashboard(:admin),   do: "/admin/overview"
  def default_dashboard(:manager), do: "/dashboard/team"
  def default_dashboard(:viewer),  do: "/dashboard/reports"

  @spec visible_sections(atom()) :: [atom()]
  def visible_sections(:admin) do
    [:overview, :users, :roles, :billing, :reports, :settings, :integrations, :audit_log]
  end

  def visible_sections(:manager) do
    [:overview, :team, :reports, :billing]
  end

  def visible_sections(:viewer) do
    [:overview, :reports]
  end


  def build_navigation(user) do
    sections = visible_sections(user.role)

    Enum.map(sections, fn section ->
      %{
        section:  section,
        path:     "/#{section}",
        label:    section |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize(),
        active:   false
      }
    end)
  end

  def landing_page(user) do
    default_dashboard(user.role)
  end
end

defmodule IAM.AuditTrail do
  @moduledoc """
  Records user activity for compliance and security monitoring purposes,
  applying role-appropriate verbosity levels and retention policies.
  """


  @spec audit_level(atom()) :: atom()
  def audit_level(:admin),   do: :verbose
  def audit_level(:manager), do: :standard
  def audit_level(:viewer),  do: :minimal

  @spec log_retention_days(atom()) :: pos_integer()
  def log_retention_days(:admin),   do: 365
  def log_retention_days(:manager), do: 180
  def log_retention_days(:viewer),  do: 90


  def record(user, action, resource, metadata \\ %{}) do
    level = audit_level(user.role)

    entry = %{
      user_id:    user.id,
      role:       user.role,
      action:     action,
      resource:   resource,
      ip_address: metadata[:ip],
      user_agent: metadata[:user_agent],
      timestamp:  DateTime.utc_now(),
      level:      level,
      retain_until: Date.add(Date.utc_today(), log_retention_days(user.role))
    }

    persist_entry(entry, level)
  end

  defp persist_entry(entry, :verbose) do
    Repo.insert_audit_log(entry)
  end

  defp persist_entry(entry, :standard) do
    small = Map.drop(entry, [:user_agent])
    Repo.insert_audit_log(small)
  end

  defp persist_entry(entry, :minimal) do
    small = Map.take(entry, [:user_id, :action, :resource, :timestamp, :retain_until])
    Repo.insert_audit_log(small)
  end
end
```
