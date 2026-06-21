```elixir
defmodule Catalog.PricingRule do
  @moduledoc """
  Evaluates tiered and volume-based pricing rules for product SKUs.
  Rules are pure data structures; evaluation is a pure function so
  the module is stateless and freely composable. Supports flat pricing,
  volume tiers, and time-bounded promotional overrides.
  """

  @enforce_keys [:sku, :strategy]
  defstruct [:sku, :strategy, :tiers, :promo_price_cents, :promo_valid_until]

  @type strategy :: :flat | :volume_tiered | :promotional
  @type tier :: %{min_qty: pos_integer(), price_cents: pos_integer()}
  @type t :: %__MODULE__{
          sku: String.t(),
          strategy: strategy(),
          tiers: [tier()] | nil,
          promo_price_cents: pos_integer() | nil,
          promo_valid_until: Date.t() | nil
        }

  @type price_result :: {:ok, non_neg_integer()} | {:error, :no_applicable_rule}

  @doc """
  Computes the unit price in cents for `sku` at `quantity` using the
  matching rule in `rules`. Returns `{:error, :no_applicable_rule}` when
  no rule is found for the SKU.
  """
  @spec unit_price([t()], String.t(), pos_integer(), Date.t()) :: price_result()
  def unit_price(rules, sku, quantity, reference_date \ Date.utc_today())
      when is_list(rules) and is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Enum.find(rules, fn r -> r.sku == sku end) do
      nil -> {:error, :no_applicable_rule}
      rule -> {:ok, evaluate(rule, quantity, reference_date)}
    end
  end

  @doc "Computes the line total in cents for `quantity` units at the evaluated price."
  @spec line_total([t()], String.t(), pos_integer(), Date.t()) :: price_result()
  def line_total(rules, sku, quantity, reference_date \ Date.utc_today()) do
    case unit_price(rules, sku, quantity, reference_date) do
      {:ok, unit} -> {:ok, unit * quantity}
      err -> err
    end
  end

  defp evaluate(%__MODULE__{strategy: :promotional} = rule, _qty, reference_date) do
    if promo_active?(rule, reference_date) do
      rule.promo_price_cents
    else
      flat_price(rule)
    end
  end

  defp evaluate(%__MODULE__{strategy: :volume_tiered} = rule, qty, _date) do
    rule.tiers
    |> Enum.filter(fn tier -> qty >= tier.min_qty end)
    |> Enum.max_by(fn tier -> tier.min_qty end, fn -> nil end)
    |> case do
      nil -> flat_price(rule)
      tier -> tier.price_cents
    end
  end

  defp evaluate(%__MODULE__{strategy: :flat} = rule, _qty, _date) do
    flat_price(rule)
  end

  defp promo_active?(%{promo_valid_until: nil}, _date), do: false
  defp promo_active?(%{promo_valid_until: until}, date) do
    Date.compare(date, until) != :gt
  end

  defp flat_price(%{tiers: [%{price_cents: p} | _]}), do: p
  defp flat_price(%{promo_price_cents: p}) when not is_nil(p), do: p
  defp flat_price(_rule), do: 0
end
```
