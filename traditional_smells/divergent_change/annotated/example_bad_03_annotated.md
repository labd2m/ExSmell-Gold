# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `SubscriptionService` module |
| **Affected functions** | `create_subscription/2`, `upgrade_plan/2`, `cancel_subscription/1` (subscription lifecycle reason) and `charge_now/1`, `apply_coupon/2`, `generate_invoice/1` (billing reason) and `record_usage/2`, `get_usage_summary/1` (usage tracking reason) |
| **Explanation** | The module handles subscription state, billing/invoicing, and usage metering — three distinct domains. Changing the billing provider, adding a new plan tier, or adjusting usage aggregation logic are all unrelated motivations that would each cause edits in this single module. |

```elixir
defmodule Billing.SubscriptionService do
  @moduledoc """
  Manages customer subscriptions, billing cycles, and usage metering.
  """

  alias Billing.Repo
  alias Billing.Subscriptions.Subscription
  alias Billing.Subscriptions.UsageRecord
  alias Billing.Invoices.Invoice
  alias Billing.Plans.Plan
  alias Billing.Payments.Gateway

  import Ecto.Query
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module has three independent reasons
  # to change: (1) subscription lifecycle rules (plans, statuses, transitions),
  # (2) billing and invoicing logic (payment provider, invoice format, coupons),
  # and (3) usage metering and aggregation. None of these cross-cuts the others.

  ## ── Subscription Lifecycle ───────────────────────────────────────────────────

  @doc "Creates a new subscription for a customer on the given plan."
  @spec create_subscription(String.t(), String.t()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def create_subscription(customer_id, plan_id) do
    plan = Repo.get!(Plan, plan_id)
    now = DateTime.utc_now()

    changeset =
      Subscription.changeset(%Subscription{}, %{
        customer_id: customer_id,
        plan_id: plan_id,
        status: :active,
        current_period_start: now,
        current_period_end: DateTime.add(now, plan.billing_interval_days * 86_400, :second)
      })

    with {:ok, sub} <- Repo.insert(changeset) do
      Logger.info("Subscription created: #{sub.id} for customer #{customer_id}")
      {:ok, sub}
    end
  end

  @doc "Upgrades or downgrades a subscription to a different plan."
  @spec upgrade_plan(Subscription.t(), String.t()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def upgrade_plan(%Subscription{} = sub, new_plan_id) do
    new_plan = Repo.get!(Plan, new_plan_id)

    sub
    |> Subscription.changeset(%{
      plan_id: new_plan_id,
      plan_changed_at: DateTime.utc_now(),
      amount_cents: new_plan.price_cents
    })
    |> Repo.update()
  end

  @doc "Cancels a subscription at the end of the current billing period."
  @spec cancel_subscription(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def cancel_subscription(%Subscription{status: :active} = sub) do
    sub
    |> Subscription.changeset(%{
      status: :cancelling,
      cancelled_at: sub.current_period_end
    })
    |> Repo.update()
  end

  def cancel_subscription(%Subscription{}), do: {:error, :already_cancelled}

  ## ── Billing & Invoicing ──────────────────────────────────────────────────────

  @doc "Immediately charges the customer for the current billing period."
  @spec charge_now(Subscription.t()) :: {:ok, map()} | {:error, term()}
  def charge_now(%Subscription{customer_id: cid, amount_cents: amount}) do
    case Gateway.charge(cid, amount, currency: "USD") do
      {:ok, charge} ->
        Logger.info("Charged customer #{cid}: #{amount} cents (charge_id=#{charge.id})")
        {:ok, charge}

      {:error, reason} = err ->
        Logger.error("Charge failed for customer #{cid}: #{inspect(reason)}")
        err
    end
  end

  @doc "Applies a discount coupon to the subscription, adjusting the billable amount."
  @spec apply_coupon(Subscription.t(), String.t()) ::
          {:ok, Subscription.t()} | {:error, atom()}
  def apply_coupon(%Subscription{} = sub, coupon_code) do
    case Billing.Coupons.lookup(coupon_code) do
      {:ok, %{discount_percent: pct}} ->
        discounted = round(sub.amount_cents * (1 - pct / 100))

        sub
        |> Subscription.changeset(%{amount_cents: discounted, coupon_code: coupon_code})
        |> Repo.update()

      {:error, :not_found} ->
        {:error, :invalid_coupon}
    end
  end

  @doc "Generates and persists a PDF invoice for the last completed billing cycle."
  @spec generate_invoice(Subscription.t()) :: {:ok, Invoice.t()} | {:error, term()}
  def generate_invoice(%Subscription{} = sub) do
    attrs = %{
      subscription_id: sub.id,
      customer_id: sub.customer_id,
      amount_cents: sub.amount_cents,
      period_start: sub.current_period_start,
      period_end: sub.current_period_end,
      issued_at: DateTime.utc_now(),
      status: :issued
    }

    Invoice.changeset(%Invoice{}, attrs) |> Repo.insert()
  end

  ## ── Usage Metering ───────────────────────────────────────────────────────────

  @doc "Records a usage event for a metered subscription."
  @spec record_usage(Subscription.t(), map()) :: {:ok, UsageRecord.t()} | {:error, term()}
  def record_usage(%Subscription{id: sub_id}, usage_attrs) do
    %UsageRecord{}
    |> UsageRecord.changeset(Map.put(usage_attrs, :subscription_id, sub_id))
    |> Repo.insert()
  end

  @doc "Returns aggregated usage for the current billing period."
  @spec get_usage_summary(Subscription.t()) :: map()
  def get_usage_summary(%Subscription{id: sub_id, current_period_start: start}) do
    UsageRecord
    |> where([u], u.subscription_id == ^sub_id and u.recorded_at >= ^start)
    |> select([u], %{
      total_units: sum(u.quantity),
      event_count: count(u.id),
      last_recorded_at: max(u.recorded_at)
    })
    |> Repo.one()
    |> case do
      nil -> %{total_units: 0, event_count: 0, last_recorded_at: nil}
      summary -> summary
    end
  end

  # VALIDATION: SMELL END
end
```
