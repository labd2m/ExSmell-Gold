# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `SubscriptionPolicy` module — functions `feature_flags/1`, `seat_limit/1`, and `support_sla_hours/1`
- **Affected functions:** `feature_flags/1`, `seat_limit/1`, `support_sla_hours/1`
- **Short explanation:** The same `case tier` branching over `:free`, `:starter`, `:professional`, and `:enterprise` is duplicated across three functions. Adding a new subscription tier forces edits in all three case blocks, which is the Switch Statements smell.

---

```elixir
defmodule SubscriptionPolicy do
  @moduledoc """
  Encodes business rules tied to subscription tiers: feature entitlements,
  seat limits, and support SLAs for the SaaS user management system.
  """

  require Logger

  @tiers [:free, :starter, :professional, :enterprise]

  def valid_tiers, do: @tiers

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over tier
  # (:free, :starter, :professional, :enterprise) is duplicated across
  # feature_flags/1, seat_limit/1, and support_sla_hours/1. A new tier
  # requires updating all three functions independently.

  @doc """
  Returns the set of feature flags that are enabled for a given subscription tier.
  """
  def feature_flags(%{tier: tier}) do
    case tier do
      :free ->
        [:basic_dashboard, :email_notifications]

      :starter ->
        [:basic_dashboard, :email_notifications, :csv_export, :api_access]

      :professional ->
        [
          :basic_dashboard,
          :email_notifications,
          :csv_export,
          :api_access,
          :advanced_reports,
          :custom_roles,
          :webhooks
        ]

      :enterprise ->
        [
          :basic_dashboard,
          :email_notifications,
          :csv_export,
          :api_access,
          :advanced_reports,
          :custom_roles,
          :webhooks,
          :sso,
          :audit_logs,
          :dedicated_support,
          :sla_guarantee
        ]

      _ ->
        [:basic_dashboard]
    end
  end

  @doc """
  Returns the maximum number of user seats allowed for the subscription tier.
  A value of `:unlimited` indicates no enforced cap.
  """
  def seat_limit(%{tier: tier}) do
    case tier do
      :free -> 1
      :starter -> 5
      :professional -> 25
      :enterprise -> :unlimited
      _ -> 1
    end
  end

  @doc """
  Returns the maximum response time in hours guaranteed under the tier's support SLA.
  A value of `nil` means best-effort with no SLA.
  """
  def support_sla_hours(%{tier: tier}) do
    case tier do
      :free -> nil
      :starter -> 72
      :professional -> 24
      :enterprise -> 4
      _ -> nil
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Checks whether a particular feature is enabled for the given subscription.
  """
  def feature_enabled?(%{} = subscription, feature) do
    feature in feature_flags(subscription)
  end

  @doc """
  Determines whether adding a new user seat is permitted given current usage.
  """
  def can_add_seat?(%{} = subscription, current_seat_count) do
    case seat_limit(subscription) do
      :unlimited -> true
      limit -> current_seat_count < limit
    end
  end

  @doc """
  Returns a formatted SLA summary string for inclusion in user-facing emails
  or support portal pages.
  """
  def sla_description(%{} = subscription) do
    case support_sla_hours(subscription) do
      nil ->
        "Support is provided on a best-effort basis with no guaranteed response time."

      hours when hours >= 48 ->
        "Our team will respond within #{hours} hours during business days."

      hours ->
        "Our team guarantees a response within #{hours} hours, 24/7."
    end
  end

  @doc """
  Generates an entitlement summary map for a subscription, used by the billing
  and account management APIs.
  """
  def entitlement_summary(%{} = subscription) do
    %{
      tier: subscription.tier,
      features: feature_flags(subscription),
      max_seats: seat_limit(subscription),
      support_sla_hours: support_sla_hours(subscription),
      sla_description: sla_description(subscription)
    }
  end

  @doc """
  Validates that a subscription struct carries a recognized tier.
  """
  def validate(%{tier: tier} = subscription) when tier in @tiers do
    {:ok, subscription}
  end

  def validate(%{tier: unknown}) do
    {:error, {:unknown_tier, unknown}}
  end

  def validate(_) do
    {:error, :missing_tier}
  end
end
```
