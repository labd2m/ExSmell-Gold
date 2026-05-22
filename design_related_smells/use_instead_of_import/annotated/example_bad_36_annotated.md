# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `BillingEngine` module, top-level directive
- **Affected function(s):** `generate_invoice/2`, `apply_credit/2`, `calculate_proration/3`
- **Short explanation:** `BillingEngine` calls `use BillingHelpers` to obtain invoice-calculation utilities. The `__using__/1` macro of `BillingHelpers` silently injects an `import` of `DateMath` into `BillingEngine`, propagating a hidden dependency on functions like `days_in_month/1`, `days_between/2`, and `next_billing_date/2`. A developer reading `BillingEngine` cannot know these functions come from `DateMath` without inspecting `BillingHelpers` internals. Replacing `use BillingHelpers` with `import BillingHelpers` would make every dependency explicit and self-documenting.

---

```elixir
defmodule DateMath do
  def days_in_month(%Date{year: y, month: m}) do
    Date.days_in_month(Date.new!(y, m, 1))
  end

  def days_between(date_a, date_b) do
    Date.diff(date_b, date_a)
  end

  def next_billing_date(anchor_day, from_date) do
    candidate = Date.new!(from_date.year, from_date.month, min(anchor_day, days_in_month(from_date)))
    if Date.compare(candidate, from_date) == :gt, do: candidate, else: Date.add(candidate, 30)
  end

  def months_between(date_a, date_b) do
    (date_b.year - date_a.year) * 12 + (date_b.month - date_a.month)
  end
end

defmodule BillingHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 injects `import DateMath`
      # VALIDATION: into BillingEngine. days_in_month/1, days_between/2,
      # VALIDATION: next_billing_date/2, and months_between/2 appear in BillingEngine
      # VALIDATION: with no visible import declaration. A maintainer reading
      # VALIDATION: BillingEngine cannot determine where these helpers originate
      # VALIDATION: without inspecting BillingHelpers internals. A plain
      # VALIDATION: `import BillingHelpers` at the call site would be transparent
      # VALIDATION: and sufficient.
      import DateMath
      # VALIDATION: SMELL END

      def line_items_total(line_items) do
        Enum.reduce(line_items, Decimal.new("0.00"), fn item, acc ->
          Decimal.add(acc, Decimal.mult(item.unit_price, Decimal.new(item.quantity)))
        end)
      end

      def apply_discount(total, %{type: :percent, value: pct}) do
        Decimal.sub(total, Decimal.mult(total, Decimal.div(pct, Decimal.new(100))))
      end
      def apply_discount(total, %{type: :fixed, value: amount}) do
        Decimal.sub(total, amount) |> Decimal.max(Decimal.new("0.00"))
      end
      def apply_discount(total, nil), do: total

      def tax_amount(subtotal, rate) do
        Decimal.mult(subtotal, Decimal.div(rate, Decimal.new(100)))
      end
    end
  end
end

defmodule BillingEngine do
  use BillingHelpers

  @default_tax_rate  Decimal.new("8.5")
  @billing_anchor    1

  def generate_invoice(subscription, opts \\ []) do
    period_start = Keyword.get(opts, :period_start, Date.utc_today())
    period_end   = next_billing_date(@billing_anchor, period_start)
    discount     = Keyword.get(opts, :discount)
    tax_rate     = Keyword.get(opts, :tax_rate, @default_tax_rate)

    subtotal = line_items_total(subscription.plan.line_items)
    after_discount = apply_discount(subtotal, discount)
    tax    = tax_amount(after_discount, tax_rate)
    total  = Decimal.add(after_discount, tax)

    %{
      id:            "inv_#{:erlang.unique_integer([:positive])}",
      subscription_id: subscription.id,
      customer_id:   subscription.customer_id,
      period_start:  period_start,
      period_end:    period_end,
      days_in_period: days_between(period_start, period_end),
      line_items:    subscription.plan.line_items,
      subtotal:      subtotal,
      discount:      discount,
      tax_rate:      tax_rate,
      tax:           tax,
      total:         total,
      due_date:      Date.add(period_start, 14),
      status:        :draft,
      issued_at:     DateTime.utc_now()
    }
  end

  def apply_credit(invoice, credit_amount) do
    remaining = Decimal.sub(invoice.total, credit_amount)
    adjusted  = Decimal.max(remaining, Decimal.new("0.00"))
    credit_applied = Decimal.sub(invoice.total, adjusted)

    %{invoice |
      credits_applied: credit_applied,
      total: adjusted,
      status: if(Decimal.equal?(adjusted, Decimal.new("0.00")), do: :paid, else: :draft)
    }
  end

  def calculate_proration(plan_amount, period_start, period_end) do
    month_date  = Date.new!(period_start.year, period_start.month, 1)
    total_days  = days_in_month(month_date)
    used_days   = days_between(period_start, period_end)

    Decimal.mult(
      plan_amount,
      Decimal.div(Decimal.new(used_days), Decimal.new(total_days))
    )
  end

  def upcoming_invoice_date(subscription) do
    next_billing_date(@billing_anchor, Date.utc_today())
  end

  def months_active(subscription) do
    months_between(subscription.started_at, Date.utc_today())
  end

  def bulk_generate(subscriptions, opts \\ []) do
    Enum.map(subscriptions, fn sub ->
      case generate_invoice(sub, opts) do
        %{total: t} = inv when not is_nil(t) -> {:ok, inv}
        _                                     -> {:error, sub.id}
      end
    end)
  end
end
```
