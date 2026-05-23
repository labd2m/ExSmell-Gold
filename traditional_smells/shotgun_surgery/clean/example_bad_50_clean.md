```elixir
defmodule MyApp.Subscriptions.FeatureGate do
  @moduledoc """
  Controls access to product features based on the organization's active subscription plan.
  Features are checked at runtime via `allowed?/2` in controllers, LiveView hooks,
  and API plugs. Each plan defines an explicit opt-in feature set.
  """

  @basic_features MapSet.new([
    :core_dashboard,
    :csv_export,
    :email_support,
    :up_to_5_users
  ])

  @professional_features MapSet.new([
    :core_dashboard,
    :csv_export,
    :pdf_export,
    :email_support,
    :priority_support,
    :api_access,
    :custom_reports,
    :webhooks,
    :up_to_25_users,
    :audit_logs
  ])

  @enterprise_features MapSet.new([
    :core_dashboard,
    :csv_export,
    :pdf_export,
    :email_support,
    :priority_support,
    :dedicated_support,
    :api_access,
    :custom_reports,
    :webhooks,
    :sso,
    :saml,
    :custom_roles,
    :unlimited_users,
    :audit_logs,
    :data_residency,
    :sla_guarantee
  ])

  def allowed?(%{plan: :basic}, feature) do
    MapSet.member?(@basic_features, feature)
  end

  def allowed?(%{plan: :professional}, feature) do
    MapSet.member?(@professional_features, feature)
  end

  def allowed?(%{plan: :enterprise}, feature) do
    MapSet.member?(@enterprise_features, feature)
  end

  def allowed?(%{plan: unknown}, _feature) do
    raise ArgumentError, "Unknown subscription plan: #{inspect(unknown)}"
  end

  def features_for(:basic), do: @basic_features
  def features_for(:professional), do: @professional_features
  def features_for(:enterprise), do: @enterprise_features
  def features_for(unknown), do: raise(ArgumentError, "Unknown plan: #{inspect(unknown)}")

  def upgrade_prompt(%{plan: :basic}, missing_feature) do
    "#{missing_feature} is available on the Professional plan. Upgrade to unlock it."
  end

  def upgrade_prompt(%{plan: :professional}, missing_feature) do
    "#{missing_feature} is available on the Enterprise plan. Upgrade to unlock it."
  end

  def upgrade_prompt(%{plan: :enterprise}, _missing_feature) do
    "Contact your account manager to enable additional features."
  end

  def upgrade_prompt(%{plan: unknown}, _feature) do
    raise ArgumentError, "Unknown plan: #{inspect(unknown)}"
  end
end

defmodule MyApp.Subscriptions.QuotaEnforcer do
  @moduledoc """
  Enforces resource consumption limits per subscription plan.
  Quotas are checked before resource-intensive operations (API calls,
  storage writes, report generation) and tracked in a Redis-backed counter store.
  """

  @quotas %{
    basic: %{
      api_calls_per_month: 1_000,
      storage_gb: 1,
      reports_per_month: 5,
      team_members: 5,
      webhooks: 0
    },
    professional: %{
      api_calls_per_month: 50_000,
      storage_gb: 20,
      reports_per_month: 100,
      team_members: 25,
      webhooks: 10
    },
    enterprise: %{
      api_calls_per_month: :unlimited,
      storage_gb: 500,
      reports_per_month: :unlimited,
      team_members: :unlimited,
      webhooks: 50
    }
  }

  def get_quota(%{plan: :basic}, resource) do
    Map.fetch!(@quotas.basic, resource)
  end

  def get_quota(%{plan: :professional}, resource) do
    Map.fetch!(@quotas.professional, resource)
  end

  def get_quota(%{plan: :enterprise}, resource) do
    Map.fetch!(@quotas.enterprise, resource)
  end

  def get_quota(%{plan: unknown}, _resource) do
    raise ArgumentError, "Unknown plan: #{inspect(unknown)}"
  end

  def check(%{plan: _} = subscription, resource, requested_amount) do
    quota = get_quota(subscription, resource)

    if quota == :unlimited do
      :ok
    else
      current = fetch_current_usage(subscription.organization_id, resource)

      if current + requested_amount <= quota do
        :ok
      else
        {:error,
         %{
           reason: :quota_exceeded,
           resource: resource,
           quota: quota,
           current_usage: current,
           requested: requested_amount
         }}
      end
    end
  end

  defp fetch_current_usage(organization_id, resource) do
    key = "quota:#{organization_id}:#{resource}:#{current_month()}"

    case Redix.command(:redix, ["GET", key]) do
      {:ok, nil} -> 0
      {:ok, val} -> String.to_integer(val)
      {:error, _} -> 0
    end
  end

  defp current_month do
    Date.utc_today() |> Date.beginning_of_month() |> Date.to_iso8601()
  end
end

defmodule MyApp.Subscriptions.BillingEngine do
  @moduledoc """
  Computes charges for each billing cycle based on the organization's plan,
  any active add-ons, and usage-based overages detected during the period.
  Returns an itemized charge breakdown ready for invoice generation.
  """

  @plan_prices %{
    basic: 29_00,
    professional: 99_00,
    enterprise: 399_00
  }

  def compute_charge(%{plan: :basic} = subscription, usage) do
    base = @plan_prices.basic

    overages =
      if usage.api_calls > 1_000 do
        extra = usage.api_calls - 1_000
        blocks = ceil(extra / 500)
        blocks * 2_00
      else
        0
      end

    %{
      plan: :basic,
      base_charge: base,
      overages: [%{resource: :api_calls, amount: overages}],
      add_ons: [],
      total: base + overages,
      currency: "USD",
      billing_period: subscription.current_period
    }
  end

  def compute_charge(%{plan: :professional} = subscription, usage) do
    base = @plan_prices.professional

    storage_overage =
      if usage.storage_gb > 20 do
        extra_gb = usage.storage_gb - 20
        extra_gb * 1_00
      else
        0
      end

    add_on_charge = Enum.sum(Enum.map(subscription.add_ons, &add_on_price/1))

    %{
      plan: :professional,
      base_charge: base,
      overages: [%{resource: :storage_gb, amount: storage_overage}],
      add_ons: Enum.map(subscription.add_ons, &%{name: &1, amount: add_on_price(&1)}),
      total: base + storage_overage + add_on_charge,
      currency: "USD",
      billing_period: subscription.current_period
    }
  end

  def compute_charge(%{plan: :enterprise} = subscription, _usage) do
    base = @plan_prices.enterprise
    add_on_charge = Enum.sum(Enum.map(subscription.add_ons, &add_on_price/1))

    %{
      plan: :enterprise,
      base_charge: base,
      overages: [],
      add_ons: Enum.map(subscription.add_ons, &%{name: &1, amount: add_on_price(&1)}),
      total: base + add_on_charge,
      currency: "USD",
      billing_period: subscription.current_period
    }
  end

  def compute_charge(%{plan: unknown}, _usage) do
    {:error, {:unsupported_plan, unknown}}
  end

  defp add_on_price(:extra_storage), do: 10_00
  defp add_on_price(:dedicated_ip), do: 25_00
  defp add_on_price(:priority_onboarding), do: 50_00
  defp add_on_price(unknown), do: raise(ArgumentError, "Unknown add-on: #{inspect(unknown)}")
end
```
