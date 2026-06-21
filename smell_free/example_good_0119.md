```elixir
defmodule Pricing.DiscountEngine do
  @moduledoc """
  Applies a prioritised stack of discount rules to a cart. Each rule is
  defined as a struct with a predicate and an effect. Rules are evaluated
  in priority order; only the first matching rule is applied unless
  rules are flagged as combinable.
  """

  @enforce_keys [:id, :label, :priority, :combinable]
  defstruct [:id, :label, :priority, :combinable, :predicate, :effect]

  @type discount_type :: :percentage | :fixed_cents
  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          priority: non_neg_integer(),
          combinable: boolean(),
          predicate: (map() -> boolean()),
          effect: {discount_type(), number()}
        }

  @type cart :: %{subtotal_cents: non_neg_integer(), item_count: non_neg_integer(), tags: [atom()]}
  @type discount :: %{rule_id: String.t(), label: String.t(), reduction_cents: non_neg_integer()}
  @type engine_result :: %{
          original_cents: non_neg_integer(),
          final_cents: non_neg_integer(),
          discounts: [discount()]
        }

  @doc """
  Evaluates the rule stack against `cart`. Returns the original and final
  totals along with a list of applied discount records.
  """
  @spec apply([t()], cart()) :: engine_result()
  def apply(rules, %{subtotal_cents: subtotal} = cart) when is_list(rules) do
    sorted = Enum.sort_by(rules, & &1.priority)
    {final_cents, discounts} = evaluate(sorted, cart, subtotal, [])

    %{
      original_cents: subtotal,
      final_cents: max(0, final_cents),
      discounts: Enum.reverse(discounts)
    }
  end

  defp evaluate([], _cart, running, discounts), do: {running, discounts}

  defp evaluate([rule | rest], cart, running, discounts) do
    if rule.predicate.(cart) do
      reduction = compute_reduction(rule.effect, running)
      discount = %{rule_id: rule.id, label: rule.label, reduction_cents: reduction}
      new_running = running - reduction

      if rule.combinable do
        evaluate(rest, cart, new_running, [discount | discounts])
      else
        {new_running, [discount | discounts]}
      end
    else
      evaluate(rest, cart, running, discounts)
    end
  end

  defp compute_reduction({:percentage, pct}, subtotal) when pct >= 0 and pct <= 100 do
    round(subtotal * pct / 100)
  end

  defp compute_reduction({:fixed_cents, amount}, subtotal) do
    min(round(amount), subtotal)
  end

  @doc """
  Constructs a percentage-based discount rule from a configuration keyword list.
  """
  @spec build_percentage_rule(keyword()) :: t()
  def build_percentage_rule(opts) do
    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      label: Keyword.fetch!(opts, :label),
      priority: Keyword.get(opts, :priority, 100),
      combinable: Keyword.get(opts, :combinable, false),
      predicate: Keyword.fetch!(opts, :predicate),
      effect: {:percentage, Keyword.fetch!(opts, :percentage)}
    }
  end

  @doc """
  Constructs a fixed-amount discount rule from a configuration keyword list.
  """
  @spec build_fixed_rule(keyword()) :: t()
  def build_fixed_rule(opts) do
    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      label: Keyword.fetch!(opts, :label),
      priority: Keyword.get(opts, :priority, 100),
      combinable: Keyword.get(opts, :combinable, false),
      predicate: Keyword.fetch!(opts, :predicate),
      effect: {:fixed_cents, Keyword.fetch!(opts, :amount_cents)}
    }
  end
end
```
