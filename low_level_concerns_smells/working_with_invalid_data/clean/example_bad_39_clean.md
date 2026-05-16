# Example 39: SaaS Subscription Billing Engine

```elixir
defmodule Billing.SubscriptionEngine do
  @moduledoc """
  Manages SaaS subscription lifecycle: plan changes, coupon application,
  proration calculations, and recurring billing cycle management.
  """

  alias Billing.{Subscription, Plan, Coupon, Invoice, Customer, AuditLog}
  alias Decimal

  @proration_strategy :daily

  def create_subscription(customer_id, plan_id, opts \\ []) do
    coupon_code = Keyword.get(opts, :coupon_code)
    trial_days = Keyword.get(opts, :trial_days, 0)

    with {:ok, customer} <- Customer.get(customer_id),
         {:ok, plan} <- Plan.get(plan_id),
         :ok <- validate_customer_eligible(customer) do

      trial_ends_at = if trial_days > 0, do: add_days(DateTime.utc_now(), trial_days), else: nil
      current_period_start = DateTime.utc_now()
      current_period_end = add_days(current_period_start, plan.billing_interval_days)

      subscription = %Subscription{
        id: generate_subscription_id(),
        customer_id: customer_id,
        plan_id: plan_id,
        status: if(trial_days > 0, do: :trialing, else: :active),
        current_period_start: current_period_start,
        current_period_end: current_period_end,
        trial_ends_at: trial_ends_at,
        coupon_code: coupon_code,
        created_at: DateTime.utc_now()
      }

      {:ok, _} = Subscription.insert(subscription)
      {:ok, _} = AuditLog.record(:subscription_created, customer_id, %{plan_id: plan_id})

      {:ok, subscription}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_coupon(subscription_id, coupon_code, invoice_amount) do
    with {:ok, subscription} <- Subscription.get(subscription_id),
         {:ok, coupon} <- Coupon.get_by_code(coupon_code),
         :ok <- validate_coupon_active(coupon),
         :ok <- validate_coupon_applicable(coupon, subscription) do

      discounted_amount =
        case coupon.discount_type do
          :percentage ->
            discount = Decimal.mult(invoice_amount, Decimal.div(coupon.discount_value, 100))
            Decimal.sub(invoice_amount, discount)

          :fixed ->
            Decimal.sub(invoice_amount, coupon.discount_value)
        end

      final_amount = Decimal.max(discounted_amount, Decimal.new(0))

      {:ok, _} = Subscription.update(subscription_id, %{coupon_code: coupon_code})
      {:ok, _} = Coupon.record_redemption(coupon.id, subscription_id)

      {:ok, %{
        original_amount: invoice_amount,
        discount_applied: Decimal.sub(invoice_amount, final_amount),
        final_amount: final_amount,
        coupon_code: coupon_code
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def upgrade_plan(subscription_id, new_plan_id) do
    with {:ok, subscription} <- Subscription.get(subscription_id),
         {:ok, current_plan} <- Plan.get(subscription.plan_id),
         {:ok, new_plan} <- Plan.get(new_plan_id),
         :ok <- validate_upgrade(current_plan, new_plan) do

      proration_credit = calculate_proration_credit(subscription, current_plan)
      proration_charge = calculate_proration_charge(subscription, new_plan)
      net_charge = Decimal.sub(proration_charge, proration_credit)

      {:ok, _} = Subscription.update(subscription_id, %{
        plan_id: new_plan_id,
        updated_at: DateTime.utc_now()
      })

      if Decimal.gt?(net_charge, Decimal.new(0)) do
        issue_immediate_invoice(subscription.customer_id, net_charge, :plan_upgrade)
      end

      {:ok, _} = AuditLog.record(:plan_upgraded, subscription.customer_id, %{
        from_plan: subscription.plan_id,
        to_plan: new_plan_id,
        net_charge: net_charge
      })

      {:ok, %{subscription_id: subscription_id, new_plan_id: new_plan_id, net_charge: net_charge}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_subscription(subscription_id, opts \\ []) do
    immediately = Keyword.get(opts, :immediately, false)
    reason = Keyword.get(opts, :reason, "customer_request")

    with {:ok, subscription} <- Subscription.get(subscription_id),
         :ok <- validate_cancellable(subscription) do

      cancel_at =
        if immediately do
          DateTime.utc_now()
        else
          subscription.current_period_end
        end

      {:ok, _} = Subscription.update(subscription_id, %{
        status: :cancelled,
        cancelled_at: DateTime.utc_now(),
        cancel_at: cancel_at,
        cancellation_reason: reason
      })

      {:ok, _} = AuditLog.record(:subscription_cancelled, subscription.customer_id, %{
        reason: reason,
        immediately: immediately
      })

      {:ok, %{subscription_id: subscription_id, cancel_at: cancel_at}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def renew_subscription(subscription_id) do
    with {:ok, subscription} <- Subscription.get(subscription_id),
         {:ok, plan} <- Plan.get(subscription.plan_id),
         {:ok, customer} <- Customer.get(subscription.customer_id),
         :ok <- validate_renewable(subscription) do

      new_period_start = subscription.current_period_end
      new_period_end = add_days(new_period_start, plan.billing_interval_days)

      invoice = %Invoice{
        id: generate_invoice_id(),
        customer_id: subscription.customer_id,
        subscription_id: subscription_id,
        amount: apply_subscription_coupon(subscription, plan.price),
        status: :pending,
        period_start: new_period_start,
        period_end: new_period_end,
        due_date: new_period_start,
        created_at: DateTime.utc_now()
      }

      {:ok, _} = Invoice.insert(invoice)
      {:ok, _} = Subscription.update(subscription_id, %{
        current_period_start: new_period_start,
        current_period_end: new_period_end
      })

      {:ok, invoice}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp calculate_proration_credit(subscription, current_plan) do
    days_remaining = DateTime.diff(subscription.current_period_end, DateTime.utc_now(), :day)
    days_total = current_plan.billing_interval_days
    daily_rate = Decimal.div(current_plan.price, Decimal.new(days_total))
    Decimal.mult(daily_rate, Decimal.new(days_remaining))
  end

  defp calculate_proration_charge(subscription, new_plan) do
    days_remaining = DateTime.diff(subscription.current_period_end, DateTime.utc_now(), :day)
    days_total = new_plan.billing_interval_days
    daily_rate = Decimal.div(new_plan.price, Decimal.new(days_total))
    Decimal.mult(daily_rate, Decimal.new(days_remaining))
  end

  defp apply_subscription_coupon(%{coupon_code: nil}, price), do: price
  defp apply_subscription_coupon(%{coupon_code: code}, price) do
    case Coupon.get_by_code(code) do
      {:ok, coupon} when coupon.status == :active ->
        Decimal.sub(price, Decimal.mult(price, Decimal.div(coupon.discount_value, 100)))
      _ ->
        price
    end
  end

  defp issue_immediate_invoice(customer_id, amount, reason) do
    invoice = %Invoice{
      id: generate_invoice_id(),
      customer_id: customer_id,
      amount: amount,
      status: :pending,
      line_item_reason: reason,
      created_at: DateTime.utc_now()
    }
    Invoice.insert(invoice)
  end

  defp validate_customer_eligible(%{status: :active}), do: :ok
  defp validate_customer_eligible(_), do: {:error, :customer_not_eligible}

  defp validate_coupon_active(%{status: :active}), do: :ok
  defp validate_coupon_active(_), do: {:error, :coupon_inactive}

  defp validate_coupon_applicable(coupon, subscription) do
    if is_nil(coupon.plan_restriction) or coupon.plan_restriction == subscription.plan_id do
      :ok
    else
      {:error, :coupon_not_applicable_to_plan}
    end
  end

  defp validate_upgrade(current_plan, new_plan) do
    if Decimal.gt?(new_plan.price, current_plan.price), do: :ok, else: {:error, :not_an_upgrade}
  end

  defp validate_cancellable(%{status: :cancelled}), do: {:error, :already_cancelled}
  defp validate_cancellable(_), do: :ok

  defp validate_renewable(%{status: :active}), do: :ok
  defp validate_renewable(%{status: :trialing}), do: :ok
  defp validate_renewable(_), do: {:error, :not_renewable}

  defp add_days(datetime, days) do
    DateTime.add(datetime, days * 86_400, :second)
  end

  defp generate_subscription_id do
    "sub_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
  end

  defp generate_invoice_id do
    "inv_#{:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)}"
  end
end
```
