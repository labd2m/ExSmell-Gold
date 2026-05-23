```elixir
defmodule Billing.RenewalEngine do
  @moduledoc """
  Handles subscription renewal cycles: calculates the amount due,
  applies plan-level discounts and addons, determines the next
  billing date, and triggers the charge attempt via the payment gateway.
  """

  alias Billing.{Subscription, SubscriptionPlan, Invoice, TaxCalculator}
  alias Payments.ChargeService

  @proration_precision 6
  @invoice_due_days    7

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Runs the renewal flow for a single subscription.
  Returns `{:ok, invoice}` on success or `{:error, reason}`.
  """
  @spec renew(String.t()) :: {:ok, Invoice.t()} | {:error, term()}
  def renew(subscription_id) do
    subscription = Subscription.get!(subscription_id)

    with :active          <- subscription.status,
         invoice_attrs    <- compute_renewal_invoice(subscription),
         {:ok, invoice}   <- Invoice.create(invoice_attrs),
         {:ok, _charge}   <- ChargeService.attempt(invoice) do
      Subscription.advance_billing_period(subscription)
      {:ok, invoice}
    else
      status when is_atom(status) -> {:error, {:not_renewable, status}}
      error -> error
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp compute_renewal_invoice(subscription) do
    plan          = SubscriptionPlan.get!(subscription.plan_id)
    tiers         = SubscriptionPlan.get_pricing_tiers(plan)
    addons        = SubscriptionPlan.applicable_addons(plan, subscription.seat_count)
    annual_disc   = SubscriptionPlan.annual_discount_rate(plan)
    tax_category  = SubscriptionPlan.tax_category(plan)
    grace_days    = SubscriptionPlan.grace_period_days(plan)

    base_amount   = tiered_price(tiers, subscription.seat_count)

    addon_total =
      Enum.reduce(addons, Decimal.new("0.00"), fn addon, acc ->
        line = Decimal.mult(addon.unit_price, subscription.seat_count)
        Decimal.add(acc, line)
      end)

    subtotal = Decimal.add(base_amount, addon_total)

    discount_amount =
      if subscription.billing_cycle == :annual do
        Decimal.mult(subtotal, annual_disc)
      else
        Decimal.new("0.00")
      end

    discounted = Decimal.sub(subtotal, discount_amount)
    tax_amount = TaxCalculator.calculate(discounted, tax_category, subscription.customer_id)
    grand_total = Decimal.add(discounted, tax_amount)

    period_start = subscription.current_period_end
    period_end   = next_period_end(period_start, subscription.billing_cycle)
    due_at       = Date.add(Date.utc_today(), @invoice_due_days)

    %{
      subscription_id: subscription.id,
      customer_id:     subscription.customer_id,
      period_start:    period_start,
      period_end:      period_end,
      due_at:          due_at,
      grace_until:     Date.add(due_at, grace_days),
      line_items:      build_line_items(base_amount, addons, discount_amount, subscription),
      subtotal:        subtotal,
      discount:        discount_amount,
      tax:             tax_amount,
      grand_total:     grand_total,
      currency:        plan.currency
    }
  end

  defp tiered_price(tiers, seat_count) do
    tier =
      Enum.find(tiers, List.last(tiers), fn t ->
        seat_count >= t.min_seats && (is_nil(t.max_seats) || seat_count <= t.max_seats)
      end)

    Decimal.mult(tier.unit_price, seat_count)
  end

  defp build_line_items(base, addons, discount, subscription) do
    base_line = %{description: "Base plan (#{subscription.seat_count} seats)", amount: base}
    addon_lines = Enum.map(addons, fn a ->
      %{description: a.name, amount: Decimal.mult(a.unit_price, subscription.seat_count)}
    end)
    discount_line = if Decimal.gt?(discount, Decimal.new(0)),
      do: [%{description: "Annual discount", amount: Decimal.negate(discount)}],
      else: []

    [base_line | addon_lines] ++ discount_line
  end

  defp next_period_end(%Date{} = start, :monthly),  do: Date.add(start, 30)
  defp next_period_end(%Date{} = start, :annual),   do: Date.add(start, 365)
  defp next_period_end(%Date{} = start, _),         do: Date.add(start, 30)
end
```
