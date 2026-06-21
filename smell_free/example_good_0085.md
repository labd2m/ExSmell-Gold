# File: `example_good_85.md`

```elixir
defmodule Pricing.RulesEngine do
  @moduledoc """
  Pure functional pricing rules engine that computes the final charge
  for an order by applying an ordered sequence of discount and surcharge
  rules to a base price.

  Rules are composable value objects. The engine itself holds no state
  and has no side effects, making it straightforward to unit-test with
  arbitrary rule combinations.
  """

  @type amount_cents :: non_neg_integer()

  @type line_item :: %{
          required(:product_id) => String.t(),
          required(:quantity) => pos_integer(),
          required(:unit_price_cents) => amount_cents()
        }

  @type rule ::
          {:percentage_discount, float()}
          | {:fixed_discount_cents, amount_cents()}
          | {:minimum_charge_cents, amount_cents()}
          | {:bulk_discount, pos_integer(), float()}
          | {:free_shipping_threshold_cents, amount_cents()}

  @type pricing_result :: %{
          subtotal_cents: amount_cents(),
          discount_cents: non_neg_integer(),
          shipping_cents: non_neg_integer(),
          total_cents: amount_cents(),
          applied_rules: [String.t()]
        }

  @doc """
  Computes the final price for a list of line items by applying `rules`
  in the order they are provided.

  Each rule may modify the running totals. Returns a pricing result
  detailing each component of the final charge.
  """
  @spec calculate([line_item()], [rule()], amount_cents()) :: pricing_result()
  def calculate(line_items, rules, base_shipping_cents \\ 0)
      when is_list(line_items) and is_list(rules) and
             is_integer(base_shipping_cents) and base_shipping_cents >= 0 do
    subtotal = compute_subtotal(line_items)

    initial = %{
      subtotal_cents: subtotal,
      discount_cents: 0,
      shipping_cents: base_shipping_cents,
      applied_rules: []
    }

    result = Enum.reduce(rules, initial, &apply_rule(&2, &1, line_items))

    Map.put(result, :total_cents, compute_total(result))
  end

  @doc """
  Computes the subtotal for a list of line items without applying any rules.
  """
  @spec subtotal([line_item()]) :: amount_cents()
  def subtotal(line_items) when is_list(line_items) do
    compute_subtotal(line_items)
  end

  defp compute_subtotal(line_items) do
    Enum.reduce(line_items, 0, fn item, acc ->
      acc + item.quantity * item.unit_price_cents
    end)
  end

  defp compute_total(%{subtotal_cents: sub, discount_cents: disc, shipping_cents: ship}) do
    max(sub - disc + ship, 0)
  end

  defp apply_rule(acc, {:percentage_discount, pct}, _items)
       when is_float(pct) and pct > 0.0 and pct <= 100.0 do
    discount = round(acc.subtotal_cents * pct / 100.0)
    label = "#{pct}% discount"
    %{acc | discount_cents: acc.discount_cents + discount, applied_rules: [label | acc.applied_rules]}
  end

  defp apply_rule(acc, {:fixed_discount_cents, amount}, _items)
       when is_integer(amount) and amount > 0 do
    discount = min(amount, acc.subtotal_cents)
    label = "Fixed discount #{amount} cents"
    %{acc | discount_cents: acc.discount_cents + discount, applied_rules: [label | acc.applied_rules]}
  end

  defp apply_rule(acc, {:minimum_charge_cents, minimum}, _items)
       when is_integer(minimum) and minimum >= 0 do
    current_total = compute_total(acc)

    if current_total < minimum do
      shortfall = minimum - current_total
      label = "Minimum charge adjustment"
      %{acc | subtotal_cents: acc.subtotal_cents + shortfall, applied_rules: [label | acc.applied_rules]}
    else
      acc
    end
  end

  defp apply_rule(acc, {:bulk_discount, threshold_qty, pct}, items)
       when is_integer(threshold_qty) and threshold_qty > 0 and is_float(pct) do
    total_qty = Enum.sum(Enum.map(items, & &1.quantity))

    if total_qty >= threshold_qty do
      discount = round(acc.subtotal_cents * pct / 100.0)
      label = "Bulk discount #{pct}% for #{total_qty} items"
      %{acc | discount_cents: acc.discount_cents + discount, applied_rules: [label | acc.applied_rules]}
    else
      acc
    end
  end

  defp apply_rule(acc, {:free_shipping_threshold_cents, threshold}, _items)
       when is_integer(threshold) and threshold >= 0 do
    if acc.subtotal_cents >= threshold do
      label = "Free shipping over #{threshold} cents"
      %{acc | shipping_cents: 0, applied_rules: [label | acc.applied_rules]}
    else
      acc
    end
  end

  defp apply_rule(acc, _unknown_rule, _items), do: acc
end
```
