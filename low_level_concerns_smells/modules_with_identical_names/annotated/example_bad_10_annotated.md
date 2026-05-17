# Annotated Example 10 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `Billing.Subscription`
- **Affected functions:** `Billing.Subscription.create/2` (file one) and `Billing.Subscription.cancel/2` (file two)
- **Explanation:** `Billing.Subscription` is defined in both `lib/billing/subscription.ex` and `lib/billing/subscription_cancellation.ex`. In BEAM, a module name maps to exactly one code version. When both files are compiled, the second overwrites the first, making either creation or cancellation logic unreachable — a critical business logic gap.

---

```elixir
# ── file: lib/billing/subscription.ex ────────────────────────────────────────

defmodule Billing.Subscription do
  @moduledoc """
  Manages the full subscription lifecycle from trial to paid.
  Creates and activates subscriptions via payment gateway integration.
  """

  alias Billing.{Plan, Customer, PaymentMethod, GatewayClient, Ledger}

  @trial_days 14

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          plan_id: String.t(),
          payment_method_id: String.t() | nil,
          status: :trialing | :active | :past_due | :cancelled | :paused,
          trial_ends_at: DateTime.t() | nil,
          current_period_start: DateTime.t(),
          current_period_end: DateTime.t(),
          cancel_at_period_end: boolean(),
          gateway_subscription_id: String.t() | nil,
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :customer_id,
    :plan_id,
    :payment_method_id,
    :trial_ends_at,
    :current_period_start,
    :current_period_end,
    :gateway_subscription_id,
    :created_at,
    status: :trialing,
    cancel_at_period_end: false
  ]

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because `Billing.Subscription` is declared again
  # in `lib/billing/subscription_cancellation.ex`. The BEAM module table holds
  # only one version. `create/2` becomes unreachable if the cancellation file
  # compiles last, silently preventing new subscriptions from being created.

  @spec create(Customer.t(), map()) :: {:ok, t()} | {:error, term()}
  def create(%Customer{} = customer, attrs) do
    plan_id = Map.fetch!(attrs, :plan_id)
    payment_method_id = Map.get(attrs, :payment_method_id)
    with_trial = Map.get(attrs, :trial, true)

    with {:ok, plan} <- Plan.fetch(plan_id),
         :ok <- validate_plan_available(plan),
         {:ok, pm} <- resolve_payment_method(customer, payment_method_id, with_trial) do
      now = DateTime.utc_now()
      trial_ends_at = if with_trial, do: DateTime.add(now, @trial_days * 86_400, :second), else: nil
      period_start = trial_ends_at || now
      period_end = DateTime.add(period_start, plan.billing_interval_days * 86_400, :second)

      gw_sub =
        unless with_trial do
          GatewayClient.create_subscription(%{
            customer_gateway_id: customer.gateway_id,
            plan_gateway_id: plan.gateway_id,
            payment_method_token: pm && pm.token
          })
        end

      sub = %__MODULE__{
        id: generate_id(),
        customer_id: customer.id,
        plan_id: plan_id,
        payment_method_id: pm && pm.id,
        status: if(with_trial, do: :trialing, else: :active),
        trial_ends_at: trial_ends_at,
        current_period_start: period_start,
        current_period_end: period_end,
        gateway_subscription_id: gw_sub && gw_sub.id,
        created_at: now
      }

      Ledger.open_subscription(sub)

      {:ok, sub}
    end
  end

  # VALIDATION: SMELL END

  @spec activate(t()) :: {:ok, t()} | {:error, term()}
  def activate(%__MODULE__{status: :trialing} = sub) do
    {:ok, %{sub | status: :active}}
  end

  def activate(_), do: {:error, :not_in_trial}

  defp validate_plan_available(%{available: true}), do: :ok
  defp validate_plan_available(_), do: {:error, :plan_unavailable}

  defp resolve_payment_method(_customer, _pm_id, true), do: {:ok, nil}

  defp resolve_payment_method(customer, nil, false) do
    case customer.default_payment_method_id do
      nil -> {:error, :payment_method_required}
      id -> PaymentMethod.fetch(id)
    end
  end

  defp resolve_payment_method(_customer, pm_id, false), do: PaymentMethod.fetch(pm_id)

  defp generate_id, do: "SUB-" <> (:crypto.strong_rand_bytes(10) |> Base.encode16())
end


# ── file: lib/billing/subscription_cancellation.ex ───────────────────────────

defmodule Billing.Subscription do
  @moduledoc """
  Handles subscription cancellation flows including immediate termination,
  cancel-at-period-end scheduling, and dunning-driven forced cancellations.
  """

  alias Billing.{GatewayClient, Ledger, AuditLog, Notifier}

  @cancellable_statuses [:trialing, :active, :paused, :past_due]

  @spec cancel(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(%{status: status} = subscription, opts \\ []) when status in @cancellable_statuses do
    immediate = Keyword.get(opts, :immediate, false)
    reason = Keyword.get(opts, :reason, :user_requested)

    if immediate do
      cancel_immediately(subscription, reason)
    else
      schedule_cancellation(subscription, reason)
    end
  end

  def cancel(_, _), do: {:error, :subscription_not_cancellable}

  @spec pause(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def pause(%{status: :active} = subscription, resume_at) do
    with {:ok, _} <- GatewayClient.pause_subscription(subscription.gateway_subscription_id) do
      updated =
        subscription
        |> Map.put(:status, :paused)
        |> Map.put(:paused_at, DateTime.utc_now())
        |> Map.put(:resume_at, resume_at)

      AuditLog.write(:subscription_paused, %{subscription_id: subscription.id})
      {:ok, updated}
    end
  end

  def pause(_, _), do: {:error, :subscription_not_pausable}

  @spec resume(map()) :: {:ok, map()} | {:error, term()}
  def resume(%{status: :paused} = subscription) do
    with {:ok, _} <- GatewayClient.resume_subscription(subscription.gateway_subscription_id) do
      updated =
        subscription
        |> Map.put(:status, :active)
        |> Map.put(:paused_at, nil)
        |> Map.put(:resume_at, nil)

      AuditLog.write(:subscription_resumed, %{subscription_id: subscription.id})
      {:ok, updated}
    end
  end

  def resume(_), do: {:error, :subscription_not_paused}

  defp cancel_immediately(subscription, reason) do
    GatewayClient.cancel_subscription(subscription.gateway_subscription_id)
    updated = Map.put(subscription, :status, :cancelled)
    Ledger.close_subscription(subscription)
    Notifier.send_cancellation_confirmation(subscription, reason)
    AuditLog.write(:subscription_cancelled, %{id: subscription.id, reason: reason, immediate: true})
    {:ok, updated}
  end

  defp schedule_cancellation(subscription, reason) do
    updated = Map.put(subscription, :cancel_at_period_end, true)
    Notifier.send_cancellation_scheduled(subscription, subscription.current_period_end)
    AuditLog.write(:subscription_cancellation_scheduled, %{id: subscription.id, reason: reason})
    {:ok, updated}
  end
end
```
