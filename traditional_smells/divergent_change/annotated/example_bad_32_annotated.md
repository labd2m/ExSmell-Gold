# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `SubscriptionManager` module (entire module)
- **Affected functions:** `create_subscription/2`, `cancel_subscription/2`, `bill_subscription/1`, `apply_promo_code/2`, `track_feature_usage/3`, `check_usage_limit/3`
- **Explanation:** `SubscriptionManager` bundles subscription lifecycle, billing logic, promotional code redemption, and feature usage tracking. These are four independent concerns — subscription state machine rules, billing calculation logic, promotion validation, and usage metering each evolve for completely different reasons.

---

```elixir
defmodule MyApp.SubscriptionManager do
  @moduledoc """
  Manages subscription lifecycle, recurring billing, promotional codes,
  and per-feature usage metering for SaaS customers.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Subscription, Invoice, PromoCode, UsageRecord}
  alias MyApp.Gateway.Stripe
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because subscription lifecycle, billing,
  # promotional code handling, and usage tracking are four separate domains
  # bundled together. Changes to plan tiers, billing cycles, promo validation
  # rules, or usage metering granularity each affect different, unrelated
  # parts of this single module.

  ## ── Subscription Lifecycle ──────────────────────────────────────────────────

  @doc """
  Creates a new subscription for a customer on the given plan.
  """
  def create_subscription(customer_id, plan_id) do
    plan = MyApp.Plans.get!(plan_id)

    with {:ok, stripe_sub} <- Stripe.create_subscription(customer_id, plan.stripe_price_id) do
      %Subscription{}
      |> Subscription.changeset(%{
        customer_id: customer_id,
        plan_id: plan_id,
        stripe_subscription_id: stripe_sub.id,
        status: :active,
        billing_cycle_anchor: Date.utc_today(),
        current_period_end: Date.add(Date.utc_today(), plan.billing_interval_days)
      })
      |> Repo.insert()
    end
  end

  @doc """
  Cancels a subscription at period end or immediately depending on the flag.
  """
  def cancel_subscription(%Subscription{} = sub, immediate? \\ false) do
    stripe_opts = if immediate?, do: %{prorate: true}, else: %{cancel_at_period_end: true}

    with {:ok, _} <- Stripe.cancel_subscription(sub.stripe_subscription_id, stripe_opts) do
      updates =
        if immediate?,
          do: %{status: :cancelled, cancelled_at: DateTime.utc_now()},
          else: %{cancel_at_period_end: true}

      sub |> Subscription.changeset(updates) |> Repo.update()
    end
  end

  ## ── Billing ─────────────────────────────────────────────────────────────────

  @doc """
  Issues an invoice for the next billing period of the subscription.
  """
  def bill_subscription(%Subscription{} = sub) do
    plan = MyApp.Plans.get!(sub.plan_id)
    amount_cents = plan.price_cents

    discounted_cents =
      case sub.promo_discount_pct do
        nil -> amount_cents
        pct -> round(amount_cents * (1 - pct / 100.0))
      end

    with {:ok, stripe_invoice} <- Stripe.create_invoice(sub.customer_id, discounted_cents) do
      %Invoice{}
      |> Invoice.changeset(%{
        subscription_id: sub.id,
        customer_id: sub.customer_id,
        stripe_invoice_id: stripe_invoice.id,
        amount_cents: discounted_cents,
        status: :open,
        due_date: Date.add(Date.utc_today(), 7),
        issued_at: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  ## ── Promotional Codes ────────────────────────────────────────────────────────

  @doc """
  Validates and applies a promotional code to a subscription.
  """
  def apply_promo_code(%Subscription{} = sub, code_string) do
    case Repo.get_by(PromoCode, code: String.upcase(code_string)) do
      nil ->
        {:error, :invalid_code}

      %PromoCode{expires_at: exp} = code when not is_nil(exp) and exp < DateTime.utc_now() ->
        {:error, :code_expired}

      %PromoCode{max_uses: max, use_count: used} = code when not is_nil(max) and used >= max ->
        {:error, :code_exhausted}

      %PromoCode{} = code ->
        Repo.transaction(fn ->
          Repo.update!(PromoCode.changeset(code, %{use_count: code.use_count + 1}))

          sub
          |> Subscription.changeset(%{
            promo_code_id: code.id,
            promo_discount_pct: code.discount_pct
          })
          |> Repo.update!()
        end)
    end
  end

  ## ── Usage Metering ───────────────────────────────────────────────────────────

  @doc """
  Records a unit of feature usage for the current billing period.
  """
  def track_feature_usage(%Subscription{} = sub, feature, units \\ 1) do
    period_start = sub.billing_cycle_anchor

    %UsageRecord{}
    |> UsageRecord.changeset(%{
      subscription_id: sub.id,
      feature: feature,
      units: units,
      period_start: period_start,
      recorded_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc """
  Checks whether the subscription has exceeded a feature's usage limit.
  """
  def check_usage_limit(%Subscription{} = sub, feature, limit) do
    period_start = sub.billing_cycle_anchor

    used =
      from(u in UsageRecord,
        where:
          u.subscription_id == ^sub.id and
            u.feature == ^feature and
            u.period_start == ^period_start,
        select: sum(u.units)
      )
      |> Repo.one()
      |> Kernel.||(0)

    if used >= limit, do: {:error, :usage_limit_exceeded}, else: {:ok, %{used: used, limit: limit}}
  end

  # VALIDATION: SMELL END
end
```
