```elixir
defmodule MyApp.Catalogue.PriceRules do
  @moduledoc """
  Evaluates customer-specific pricing rules to determine the effective
  price for a product. Rules are prioritised and the highest-matching
  rule wins. Rule sources include volume discounts, customer contract
  prices, promotional overrides, and currency-adjusted list prices.

  All calculation is purely functional; callers fetch and supply the
  applicable rules from the database before calling `resolve/3`.
  """

  @type price_rule :: %{
          required(:type) => :contract | :volume | :promotional | :list,
          required(:priority) => pos_integer(),
          optional(:min_quantity) => pos_integer(),
          optional(:price_cents) => pos_integer(),
          optional(:discount_bps) => non_neg_integer(),
          optional(:expires_at) => DateTime.t() | nil
        }

  @type resolve_result :: %{
          price_cents: pos_integer(),
          original_price_cents: pos_integer(),
          discount_bps: non_neg_integer(),
          rule_type: atom(),
          rule_priority: pos_integer()
        }

  @doc """
  Resolves the effective unit price for `product` given `quantity` and
  the set of `rules` applicable to the buyer. Returns the winning rule
  result or the list price when no rules match.
  """
  @spec resolve(pos_integer(), pos_integer(), [price_rule()]) :: resolve_result()
  def resolve(list_price_cents, quantity, rules)
      when is_integer(list_price_cents) and list_price_cents > 0 and
             is_integer(quantity) and quantity > 0 do
    applicable =
      rules
      |> Enum.filter(&applicable?(&1, quantity))
      |> Enum.sort_by(& &1.priority, :desc)

    case applicable do
      [] ->
        fallback(list_price_cents)

      [winning | _] ->
        apply_rule(winning, list_price_cents)
    end
  end

  @doc "Returns `true` when `rule` is currently active and quantity-eligible."
  @spec applicable?(price_rule(), pos_integer()) :: boolean()
  def applicable?(rule, quantity) do
    quantity_eligible?(rule, quantity) and not expired?(rule)
  end

  @spec apply_rule(price_rule(), pos_integer()) :: resolve_result()
  defp apply_rule(%{type: :contract, price_cents: price} = rule, list_price) do
    discount = discount_from_prices(list_price, price)

    %{
      price_cents: price,
      original_price_cents: list_price,
      discount_bps: discount,
      rule_type: :contract,
      rule_priority: rule.priority
    }
  end

  defp apply_rule(%{type: :volume, discount_bps: bps} = rule, list_price) do
    discount_cents = div(list_price * bps, 10_000)
    effective = max(list_price - discount_cents, 1)

    %{
      price_cents: effective,
      original_price_cents: list_price,
      discount_bps: bps,
      rule_type: :volume,
      rule_priority: rule.priority
    }
  end

  defp apply_rule(%{type: :promotional, price_cents: price} = rule, list_price) do
    discount = discount_from_prices(list_price, price)

    %{
      price_cents: price,
      original_price_cents: list_price,
      discount_bps: discount,
      rule_type: :promotional,
      rule_priority: rule.priority
    }
  end

  defp apply_rule(rule, list_price), do: fallback(list_price, rule.priority)

  @spec fallback(pos_integer(), pos_integer()) :: resolve_result()
  defp fallback(list_price, priority \\ 0) do
    %{
      price_cents: list_price,
      original_price_cents: list_price,
      discount_bps: 0,
      rule_type: :list,
      rule_priority: priority
    }
  end

  @spec quantity_eligible?(price_rule(), pos_integer()) :: boolean()
  defp quantity_eligible?(%{min_quantity: min}, qty) when is_integer(min), do: qty >= min
  defp quantity_eligible?(_, _), do: true

  @spec expired?(price_rule()) :: boolean()
  defp expired?(%{expires_at: nil}), do: false
  defp expired?(%{expires_at: expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) == :gt

  defp expired?(_), do: false

  @spec discount_from_prices(pos_integer(), pos_integer()) :: non_neg_integer()
  defp discount_from_prices(list, effective) when list > 0 do
    max(round((list - effective) / list * 10_000), 0)
  end

  defp discount_from_prices(_, _), do: 0
end
```
