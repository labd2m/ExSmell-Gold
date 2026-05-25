# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `SubscriptionManager` module
- **Affected function(s):** `subscribe/3`, `upgrade_plan/2`, `downgrade_plan/2`, `cancel/2`, `reactivate/1`, `apply_trial/2`, `record_usage/3`, `get_usage_summary/2`, `check_feature_access/2`, `enforce_seat_limit/2`, `generate_renewal_invoice/1`
- **Short explanation:** `SubscriptionManager` handles subscription creation, plan upgrades/downgrades, cancellation lifecycle, trial management, metered usage recording and summarization, feature-flag access, seat enforcement, and invoice generation — eight distinct concerns that should be split into modules like `PlanTransition`, `TrialManager`, `UsageTracker`, `FeatureAccess`, `SeatEnforcer`, and `RenewalBilling`.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because SubscriptionManager conflates subscription
# creation and lifecycle (subscribe, upgrade, downgrade, cancel, reactivate),
# trial management, metered usage tracking and summarization, feature-flag
# access control, seat-count enforcement, and renewal invoice generation —
# all distinct business concerns that bloat this single module.
defmodule MyApp.SubscriptionManager do
  @moduledoc """
  Manages customer subscriptions including plan management, trials,
  metered usage, feature access, seat limits, and renewal billing.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Billing.{Subscription, UsageRecord, SubscriptionEvent}
  alias MyApp.Accounts.{User, Organization}
  alias MyApp.BillingManager

  @plans %{
    "starter"    => %{price: 2900,  seats: 5,   features: [:core],              metered: false},
    "growth"     => %{price: 7900,  seats: 20,  features: [:core, :analytics],  metered: false},
    "business"   => %{price: 19900, seats: 100, features: [:core, :analytics, :api], metered: true},
    "enterprise" => %{price: 49900, seats: nil, features: [:core, :analytics, :api, :sso], metered: true}
  }

  @trial_days 14

  # -------------------------------------------------------------------
  # Subscription lifecycle
  # -------------------------------------------------------------------

  def subscribe(%Organization{} = org, plan_name, payment_method) do
    case Map.fetch(@plans, plan_name) do
      :error ->
        {:error, "Unknown plan: #{plan_name}"}

      {:ok, plan} ->
        existing = Repo.get_by(Subscription, organization_id: org.id, status: :active)

        if existing do
          {:error, :already_subscribed}
        else
          Repo.transaction(fn ->
            sub = Repo.insert!(%Subscription{
              organization_id: org.id,
              plan_name:       plan_name,
              status:          :active,
              price_cents:     plan.price,
              current_period_start: Date.utc_today(),
              current_period_end:   Date.add(Date.utc_today(), 30),
              payment_method:  payment_method
            })

            record_sub_event(sub.id, :created, %{plan: plan_name})

            MyApp.Mailer.deliver(%{
              to:      org.billing_email,
              subject: "Subscription started: #{plan_name}",
              body:    "Your #{plan_name} plan is now active."
            })

            sub
          end)
        end
    end
  end

  def upgrade_plan(%Subscription{} = sub, new_plan) do
    with {:ok, plan_info} <- fetch_plan(new_plan),
         :ok              <- validate_upgrade(sub.plan_name, new_plan) do

      old_plan = sub.plan_name
      updated  = Repo.update!(Subscription.changeset(sub, %{plan_name: new_plan, price_cents: plan_info.price}))
      record_sub_event(sub.id, :upgraded, %{from: old_plan, to: new_plan})
      notify_plan_change(sub.organization_id, :upgraded, old_plan, new_plan)
      {:ok, updated}
    end
  end

  def downgrade_plan(%Subscription{} = sub, new_plan) do
    with {:ok, plan_info} <- fetch_plan(new_plan),
         :ok              <- validate_downgrade(sub.plan_name, new_plan) do

      old_plan = sub.plan_name
      updated  = Repo.update!(Subscription.changeset(sub, %{
        plan_name:            new_plan,
        price_cents:          plan_info.price,
        downgrade_pending_at: DateTime.utc_now(),
        pending_plan:         new_plan
      }))

      record_sub_event(sub.id, :downgrade_scheduled, %{from: old_plan, to: new_plan})
      notify_plan_change(sub.organization_id, :downgraded, old_plan, new_plan)
      {:ok, updated}
    end
  end

  def cancel(%Subscription{status: :active} = sub, reason) do
    Repo.update!(Subscription.changeset(sub, %{
      status:       :canceled,
      canceled_at:  DateTime.utc_now(),
      cancel_reason: reason
    }))

    record_sub_event(sub.id, :canceled, %{reason: reason})

    org = Repo.get!(Organization, sub.organization_id)
    MyApp.Mailer.deliver(%{
      to:      org.billing_email,
      subject: "Subscription canceled",
      body:    "Your subscription has been canceled. Reason: #{reason}."
    })

    :ok
  end

  def cancel(%Subscription{status: s}, _), do: {:error, "Cannot cancel in status #{s}"}

  def reactivate(%Subscription{status: :canceled} = sub) do
    updated = Repo.update!(Subscription.changeset(sub, %{
      status:       :active,
      canceled_at:  nil,
      cancel_reason: nil,
      current_period_start: Date.utc_today(),
      current_period_end:   Date.add(Date.utc_today(), 30)
    }))

    record_sub_event(sub.id, :reactivated, %{})
    {:ok, updated}
  end

  def reactivate(%Subscription{status: s}), do: {:error, "Cannot reactivate in status #{s}"}

  # -------------------------------------------------------------------
  # Trial management
  # -------------------------------------------------------------------

  def apply_trial(%Organization{} = org, plan_name) do
    if Repo.exists?(from s in Subscription, where: s.organization_id == ^org.id) do
      {:error, :trial_not_eligible}
    else
      Repo.insert!(%Subscription{
        organization_id:      org.id,
        plan_name:            plan_name,
        status:               :trialing,
        price_cents:          0,
        trial_ends_at:        Date.add(Date.utc_today(), @trial_days),
        current_period_start: Date.utc_today(),
        current_period_end:   Date.add(Date.utc_today(), @trial_days)
      })

      {:ok, :trial_started}
    end
  end

  # -------------------------------------------------------------------
  # Metered usage
  # -------------------------------------------------------------------

  def record_usage(%Subscription{} = sub, metric, quantity) when quantity > 0 do
    plan = Map.get(@plans, sub.plan_name, %{})

    unless plan[:metered] do
      Logger.warning("Usage recorded on non-metered plan #{sub.plan_name}")
    end

    Repo.insert!(%UsageRecord{
      subscription_id: sub.id,
      metric:          metric,
      quantity:        quantity,
      recorded_at:     DateTime.utc_now()
    })

    :ok
  end

  def get_usage_summary(%Subscription{} = sub, period_start) do
    from(ur in UsageRecord,
      where: ur.subscription_id == ^sub.id and ur.recorded_at >= ^period_start,
      group_by: ur.metric,
      select: %{metric: ur.metric, total: sum(ur.quantity)}
    )
    |> Repo.all()
    |> Map.new(fn %{metric: m, total: t} -> {m, t} end)
  end

  # -------------------------------------------------------------------
  # Feature access
  # -------------------------------------------------------------------

  def check_feature_access(%Subscription{} = sub, feature) when is_atom(feature) do
    plan_info = Map.get(@plans, sub.plan_name, %{features: []})

    cond do
      sub.status not in [:active, :trialing] -> {:error, :subscription_inactive}
      feature in plan_info.features          -> :ok
      true                                   -> {:error, :feature_not_included}
    end
  end

  # -------------------------------------------------------------------
  # Seat enforcement
  # -------------------------------------------------------------------

  def enforce_seat_limit(%Subscription{} = sub, %Organization{} = org) do
    plan_info  = Map.get(@plans, sub.plan_name, %{seats: 1})
    seat_limit = plan_info[:seats]

    if is_nil(seat_limit) do
      :ok
    else
      active_seats = Repo.aggregate(
        from(u in User, where: u.organization_id == ^org.id and u.status == :active),
        :count, :id
      )

      if active_seats >= seat_limit,
        do: {:error, {:seat_limit_reached, seat_limit}},
        else: :ok
    end
  end

  # -------------------------------------------------------------------
  # Renewal billing
  # -------------------------------------------------------------------

  def generate_renewal_invoice(%Subscription{status: :active} = sub) do
    org = Repo.get!(Organization, sub.organization_id)

    line_items = [%{
      quantity:    1,
      unit_price:  sub.price_cents,
      description: "#{sub.plan_name} plan – monthly renewal"
    }]

    owner = Repo.get_by!(User, organization_id: org.id, role: :owner)

    {:ok, invoice} = BillingManager.create_invoice(owner, line_items)

    Repo.update!(Subscription.changeset(sub, %{
      renewal_invoice_id:  invoice.id,
      current_period_start: sub.current_period_end,
      current_period_end:   Date.add(sub.current_period_end, 30)
    }))

    {:ok, invoice}
  end

  def generate_renewal_invoice(%Subscription{status: s}),
    do: {:error, "Cannot renew in status #{s}"}

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp fetch_plan(name) do
    case Map.fetch(@plans, name) do
      {:ok, p} -> {:ok, p}
      :error   -> {:error, "Unknown plan: #{name}"}
    end
  end

  defp validate_upgrade(from_plan, to_plan) do
    order = Map.keys(@plans) |> Enum.with_index() |> Map.new()
    if Map.get(order, to_plan, 0) > Map.get(order, from_plan, 0), do: :ok, else: {:error, :not_an_upgrade}
  end

  defp validate_downgrade(from_plan, to_plan) do
    order = Map.keys(@plans) |> Enum.with_index() |> Map.new()
    if Map.get(order, to_plan, 0) < Map.get(order, from_plan, 0), do: :ok, else: {:error, :not_a_downgrade}
  end

  defp record_sub_event(sub_id, event_type, metadata) do
    Repo.insert!(%SubscriptionEvent{
      subscription_id: sub_id,
      event_type:      event_type,
      metadata:        metadata,
      occurred_at:     DateTime.utc_now()
    })
  end

  defp notify_plan_change(org_id, change_type, old_plan, new_plan) do
    org = Repo.get!(Organization, org_id)
    MyApp.Mailer.deliver(%{
      to:      org.billing_email,
      subject: "Plan #{change_type}",
      body:    "Your plan changed from #{old_plan} to #{new_plan}."
    })
  end
end
# VALIDATION: SMELL END
```
