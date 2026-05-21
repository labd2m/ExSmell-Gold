```elixir
defmodule Billing.SubscriptionCalculator do
  @moduledoc """
  Computes subscription billing amounts including proration, discounts,
  add-on charges, and tax for the monthly billing cycle.
  """

  alias Billing.{Charge, Discount, TaxRule, Subscription}

  @proration_precision 4
  @minimum_charge_cents 50

  def compute_invoice_total(%Subscription{} = sub, billing_date) do
    with {:ok, charges} <- build_charge_list(sub, billing_date),
         {:ok, discounts} <- Discount.applicable_for(sub),
         {:ok, tax_rule} <- TaxRule.for_customer(sub.customer_id) do
      base_total = sum_line_amounts(charges)
      discount_total = apply_discounts(base_total, discounts)
      tax_amount = TaxRule.compute(tax_rule, discount_total)
      grand_total = Decimal.add(discount_total, tax_amount)

      result = %{
        charges: charges,
        discounts: discounts,
        base_total: base_total,
        discount_total: discount_total,
        tax_amount: tax_amount,
        grand_total: grand_total,
        currency: sub.currency,
        billing_date: billing_date
      }

      {:ok, result}
    end
  end

  def sum_line_amounts(charges) do
    Enum.reduce(charges, Decimal.new(0), fn %Charge{amount: amount}, acc ->
      Decimal.add(acc, amount)
    end)
  end

  def build_charge_list(%Subscription{plan: plan, add_ons: add_ons} = sub, billing_date) do
    base_charge = %Charge{
      type: :base_plan,
      description: plan.name,
      amount: plan.price,
      quantity: 1
    }

    proration = compute_proration(sub, billing_date)

    add_on_charges =
      Enum.map(add_ons, fn add_on ->
        %Charge{
          type: :add_on,
          description: add_on.name,
          amount: add_on.price,
          quantity: add_on.quantity
        }
      end)

    all_charges = [base_charge | add_on_charges] ++ List.wrap(proration)

    below_minimum =
      all_charges
      |> Enum.map(& &1.amount)
      |> Enum.all?(fn amount -> Decimal.compare(amount, Decimal.new(@minimum_charge_cents)) == :lt end)

    if below_minimum do
      {:error, :total_below_minimum_charge}
    else
      {:ok, all_charges}
    end
  end

  def apply_discounts(amount, []), do: amount

  def apply_discounts(amount, discounts) do
    Enum.reduce(discounts, amount, fn discount, acc ->
      case discount.type do
        :percentage ->
          factor = Decimal.sub(Decimal.new(1), discount.value)
          Decimal.mult(acc, factor)

        :fixed ->
          Decimal.sub(acc, discount.value)
      end
    end)
  end

  defp compute_proration(%Subscription{billing_cycle_start: nil}, _), do: nil

  defp compute_proration(%Subscription{plan: plan, billing_cycle_start: start_date}, billing_date) do
    days_in_cycle = Date.diff(billing_date, start_date)
    days_in_month = Date.days_in_month(billing_date)
    daily_rate = Decimal.div(plan.price, Decimal.new(days_in_month))
    prorated_amount = Decimal.mult(daily_rate, Decimal.new(days_in_cycle)) |> Decimal.round(@proration_precision)

    %Charge{type: :proration, description: "Proration adjustment", amount: prorated_amount, quantity: 1}
  end
end
```
