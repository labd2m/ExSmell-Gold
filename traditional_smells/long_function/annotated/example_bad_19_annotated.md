# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Billing.ChargeCalculator.calculate/3`
- **Affected function(s):** `calculate/3`
- **Short explanation:** The `calculate/3` function handles plan tier lookup, usage-based metered component calculation, per-seat pricing, annual discount application, trial-period credit, tax rule resolution, and final charge assembly all in one monolithic function. Each pricing dimension is a discrete computation that belongs in its own helper, not piled into a single body.

---

```elixir
defmodule Billing.ChargeCalculator do
  @moduledoc """
  Calculates the total charge for a subscription billing cycle,
  applying tiered pricing, seat fees, usage overages, and tax rules.
  """

  alias Billing.{Plan, Subscription, UsageRecord, TaxRule, Repo}
  require Logger

  @annual_discount_rate 0.15
  @trial_extension_days 7

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `calculate/3` embeds plan tier resolution,
  # VALIDATION: per-seat computation, metered usage overage calculation, annual
  # VALIDATION: discount logic, trial credit handling, tax resolution, and final
  # VALIDATION: charge map assembly all in a single function with no decomposition.
  def calculate(%Subscription{} = sub, billing_period_start, billing_period_end) do
    Logger.info("Calculating charge for sub=#{sub.id} period=#{billing_period_start}")

    # --- Load plan ---
    plan = Repo.get!(Plan, sub.plan_id)

    # --- Determine base fee by tier ---
    base_fee_cents =
      cond do
        plan.tier == :starter  -> 1_900
        plan.tier == :growth   -> 4_900
        plan.tier == :business -> 12_900
        plan.tier == :enterprise -> sub.negotiated_price_cents || 25_000
        true -> 0
      end

    # --- Per-seat fee ---
    seat_count = sub.seat_count || 1
    included_seats = plan.included_seats || 1

    additional_seats = max(seat_count - included_seats, 0)
    seat_fee_cents = additional_seats * (plan.per_seat_price_cents || 500)

    # --- Metered usage overage ---
    usage_records =
      UsageRecord
      |> UsageRecord.for_subscription(sub.id)
      |> UsageRecord.between(billing_period_start, billing_period_end)
      |> Repo.all()

    total_units_used = Enum.reduce(usage_records, 0, fn r, acc -> acc + r.quantity end)
    included_units = plan.included_units || 0

    overage_units = max(total_units_used - included_units, 0)
    overage_cents = overage_units * (plan.overage_price_cents || 1)

    Logger.debug("Sub #{sub.id}: base=#{base_fee_cents} seats=#{seat_fee_cents} overage=#{overage_cents}")

    # --- Subtotal before discounts ---
    subtotal_cents = base_fee_cents + seat_fee_cents + overage_cents

    # --- Apply annual billing discount ---
    discount_cents =
      if sub.billing_interval == :annual do
        round(subtotal_cents * @annual_discount_rate)
      else
        0
      end

    discounted_cents = subtotal_cents - discount_cents

    # --- Trial period credit ---
    trial_credit_cents =
      if not is_nil(sub.trial_ends_at) do
        days_remaining = DateTime.diff(sub.trial_ends_at, billing_period_start, :second) |> div(86_400)
        credited_days = min(max(days_remaining, 0), @trial_extension_days)

        if credited_days > 0 do
          days_in_period = DateTime.diff(billing_period_end, billing_period_start, :second) |> div(86_400)
          if days_in_period > 0 do
            round(base_fee_cents * credited_days / days_in_period)
          else
            0
          end
        else
          0
        end
      else
        0
      end

    chargeable_cents = max(discounted_cents - trial_credit_cents, 0)

    # --- Tax calculation ---
    {tax_rate, tax_description} =
      case Repo.get_by(TaxRule, country: sub.billing_country) do
        nil  -> {0.0, "No tax"}
        rule -> {rule.rate, rule.description}
      end

    tax_cents = round(chargeable_cents * tax_rate)
    total_cents = chargeable_cents + tax_cents

    result = %{
      subscription_id: sub.id,
      billing_period_start: billing_period_start,
      billing_period_end: billing_period_end,
      base_fee_cents: base_fee_cents,
      seat_fee_cents: seat_fee_cents,
      overage_cents: overage_cents,
      subtotal_cents: subtotal_cents,
      discount_cents: discount_cents,
      trial_credit_cents: trial_credit_cents,
      chargeable_cents: chargeable_cents,
      tax_rate: tax_rate,
      tax_description: tax_description,
      tax_cents: tax_cents,
      total_cents: total_cents,
      currency: sub.currency || "usd",
      calculated_at: DateTime.utc_now()
    }

    Logger.info("Charge calculated for sub #{sub.id}: total=#{total_cents} cents")
    {:ok, result}
  end
  # VALIDATION: SMELL END
end
```
