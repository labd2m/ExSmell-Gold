# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `SubscriptionPolicy.enabled_features/1` and `SubscriptionPolicy.max_seats/1`
- **Affected functions:** `enabled_features/1`, `max_seats/1`
- **Short explanation:** The same `case` branching over subscription plan (`:free`, `:starter`, `:professional`, `:enterprise`) is duplicated in `enabled_features/1` and `max_seats/1`. Adding a new plan tier requires updating both case blocks independently.

---

```elixir
defmodule SubscriptionPolicy do
  @moduledoc """
  Enforces feature availability and seat limits based on a
  team's active subscription plan in a SaaS product.
  """

  alias SubscriptionPolicy.{Team, Subscription, UsageRecord}

  @type plan :: :free | :starter | :professional | :enterprise

  @spec check_feature_access(Team.t(), atom()) :: :ok | {:error, :feature_not_available}
  def check_feature_access(%Team{subscription: subscription}, feature) do
    features = enabled_features(subscription.plan)

    if feature in features do
      :ok
    else
      {:error, :feature_not_available}
    end
  end

  @spec check_seat_availability(Team.t()) :: :ok | {:error, :seat_limit_reached}
  def check_seat_availability(%Team{subscription: subscription} = team) do
    limit = max_seats(subscription.plan)
    current = count_active_members(team)

    if current < limit do
      :ok
    else
      {:error, :seat_limit_reached}
    end
  end

  @spec subscription_summary(Team.t()) :: map()
  def subscription_summary(%Team{subscription: subscription} = team) do
    limit = max_seats(subscription.plan)
    used = count_active_members(team)

    %{
      plan: subscription.plan,
      seats_used: used,
      seats_available: limit - used,
      seats_limit: limit,
      features: enabled_features(subscription.plan),
      renewal_date: subscription.renews_at
    }
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `plan`
  # also appears in `max_seats/1` below. Both enumerate :free, :starter,
  # :professional, :enterprise — adding a new plan forces edits in both.
  @spec enabled_features(plan()) :: [atom()]
  def enabled_features(plan) do
    case plan do
      :free ->
        [:basic_dashboard, :csv_export]

      :starter ->
        [:basic_dashboard, :csv_export, :api_access,
         :team_collaboration, :email_reports]

      :professional ->
        [:basic_dashboard, :csv_export, :api_access,
         :team_collaboration, :email_reports, :advanced_analytics,
         :custom_branding, :sso, :audit_log]

      :enterprise ->
        [:basic_dashboard, :csv_export, :api_access,
         :team_collaboration, :email_reports, :advanced_analytics,
         :custom_branding, :sso, :audit_log,
         :dedicated_support, :custom_contracts, :saml, :scim]
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `plan`
  # already appeared in `enabled_features/1` above. The plan atoms are fully
  # repeated, meaning any new plan must be registered in two separate functions.
  @spec max_seats(plan()) :: integer()
  def max_seats(plan) do
    case plan do
      :free         -> 3
      :starter      -> 10
      :professional -> 50
      :enterprise   -> 500
    end
  end
  # VALIDATION: SMELL END

  @spec upgrade_available?(plan()) :: boolean()
  def upgrade_available?(plan), do: plan != :enterprise

  @spec count_active_members(Team.t()) :: integer()
  defp count_active_members(%Team{id: team_id}) do
    UsageRecord.active_member_count(team_id)
  end

  @spec plan_display_name(plan()) :: String.t()
  def plan_display_name(plan) do
    plan |> Atom.to_string() |> String.capitalize()
  end
end
```
