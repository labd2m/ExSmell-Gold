# Smell: Shotgun Surgery

- **Smell Name:** Shotgun Surgery
- **Expected Smell Location:** `MyApp.Accounts.PermissionPolicy`, `MyApp.Accounts.DashboardConfig`, `MyApp.Accounts.OnboardingFlow`
- **Affected Functions:** `PermissionPolicy.permissions_for/1`, `DashboardConfig.widgets_for/1`, `OnboardingFlow.steps_for/1`
- **Explanation:** Adding a new user role (e.g., `:moderator`) requires small but mandatory changes scattered across all three modules: permission grants in `PermissionPolicy`, dashboard widgets in `DashboardConfig`, and onboarding steps in `OnboardingFlow`. Role-specific behavior is spread thin rather than consolidated.

```elixir
# VALIDATION: SMELL START - Shotgun Surgery
# VALIDATION: This is a smell because adding a new role (e.g., :moderator) forces changes in
# VALIDATION: PermissionPolicy.permissions_for/1 (access rules), DashboardConfig.widgets_for/1
# VALIDATION: (UI configuration), and OnboardingFlow.steps_for/1 (onboarding tasks).
# VALIDATION: Each module independently encodes role knowledge, so a new role
# VALIDATION: must be threaded through all three modules separately.

defmodule MyApp.Accounts.PermissionPolicy do
  @moduledoc """
  Defines capability sets for each application role.
  Permissions are expressed as atom lists and checked at runtime
  via `can?/2` guards in controllers and LiveView event handlers.
  """

  @admin_permissions [
    :manage_users,
    :manage_billing,
    :view_audit_logs,
    :manage_integrations,
    :export_data,
    :manage_roles,
    :view_reports,
    :manage_content,
    :view_analytics
  ]

  @manager_permissions [
    :view_users,
    :manage_content,
    :view_reports,
    :view_analytics,
    :export_data
  ]

  @viewer_permissions [
    :view_reports,
    :view_analytics
  ]

  def permissions_for(:admin), do: @admin_permissions
  def permissions_for(:manager), do: @manager_permissions
  def permissions_for(:viewer), do: @viewer_permissions
  def permissions_for(unknown), do: raise(ArgumentError, "Unknown role: #{inspect(unknown)}")

  def can?(%{role: role}, permission) do
    permission in permissions_for(role)
  end

  def highest_role(roles) do
    priority = %{admin: 3, manager: 2, viewer: 1}
    Enum.max_by(roles, &Map.get(priority, &1, 0))
  end
end

defmodule MyApp.Accounts.DashboardConfig do
  @moduledoc """
  Returns the ordered list of dashboard widget identifiers available to each role.
  Widgets are rendered by the LiveView dashboard component in the order specified here.
  Feature-flagged widgets are included only when the corresponding flag is enabled.
  """

  alias MyApp.FeatureFlags

  def widgets_for(:admin) do
    base = [
      :kpi_summary,
      :revenue_chart,
      :active_users,
      :recent_audit_log,
      :billing_status,
      :integration_health,
      :role_distribution
    ]

    if FeatureFlags.enabled?(:ai_insights) do
      base ++ [:ai_recommendations]
    else
      base
    end
  end

  def widgets_for(:manager) do
    base = [
      :kpi_summary,
      :revenue_chart,
      :active_users,
      :content_performance,
      :team_activity
    ]

    if FeatureFlags.enabled?(:ai_insights) do
      base ++ [:ai_recommendations]
    else
      base
    end
  end

  def widgets_for(:viewer) do
    [
      :kpi_summary,
      :revenue_chart,
      :active_users
    ]
  end

  def widgets_for(unknown) do
    raise ArgumentError, "No dashboard configuration for role: #{inspect(unknown)}"
  end

  def sidebar_items_for(:admin) do
    [:dashboard, :users, :billing, :integrations, :audit_logs, :settings]
  end

  def sidebar_items_for(:manager) do
    [:dashboard, :content, :reports, :team]
  end

  def sidebar_items_for(:viewer) do
    [:dashboard, :reports]
  end

  def sidebar_items_for(unknown) do
    raise ArgumentError, "No sidebar configuration for role: #{inspect(unknown)}"
  end
end

defmodule MyApp.Accounts.OnboardingFlow do
  @moduledoc """
  Defines role-specific onboarding steps displayed to new users upon first login.
  Steps are presented sequentially in the onboarding wizard and tracked per-user
  in the `onboarding_progress` table until all are completed or dismissed.
  """

  alias MyApp.Accounts.OnboardingStep

  def steps_for(:admin) do
    [
      %OnboardingStep{
        key: :verify_email,
        title: "Verify your email address",
        description: "Check your inbox for a verification link.",
        required: true
      },
      %OnboardingStep{
        key: :configure_billing,
        title: "Set up billing",
        description: "Add a payment method to activate your account.",
        required: true
      },
      %OnboardingStep{
        key: :invite_team,
        title: "Invite your team",
        description: "Add colleagues and assign roles.",
        required: false
      },
      %OnboardingStep{
        key: :connect_integration,
        title: "Connect an integration",
        description: "Link your existing tools to get started.",
        required: false
      }
    ]
  end

  def steps_for(:manager) do
    [
      %OnboardingStep{
        key: :verify_email,
        title: "Verify your email address",
        description: "Check your inbox for a verification link.",
        required: true
      },
      %OnboardingStep{
        key: :complete_profile,
        title: "Complete your profile",
        description: "Add your name, photo, and department.",
        required: false
      },
      %OnboardingStep{
        key: :explore_reports,
        title: "Explore your reports",
        description: "Take a tour of the reporting dashboard.",
        required: false
      }
    ]
  end

  def steps_for(:viewer) do
    [
      %OnboardingStep{
        key: :verify_email,
        title: "Verify your email address",
        description: "Check your inbox for a verification link.",
        required: true
      },
      %OnboardingStep{
        key: :explore_dashboard,
        title: "Explore the dashboard",
        description: "Take a look at the main metrics available to you.",
        required: false
      }
    ]
  end

  def steps_for(unknown) do
    raise ArgumentError, "No onboarding flow defined for role: #{inspect(unknown)}"
  end

  def next_incomplete_step(user) do
    user.role
    |> steps_for()
    |> Enum.find(fn step ->
      not MapSet.member?(user.completed_onboarding_steps, step.key)
    end)
  end
end
# VALIDATION: SMELL END
```
