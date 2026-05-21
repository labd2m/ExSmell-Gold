# Annotated Example – Code Organization by Process

## Metadata

- **Smell name**: Code organization by process
- **Expected smell location**: `Commerce.PricingEngine` module
- **Affected function(s)**: `unit_price/3`, `bulk_price/3`, `tiered_price/3`, `margin/3`
- **Short explanation**: Pricing calculation is purely mathematical: given a base price, a quantity, and optional tier rules, compute a final price. No shared mutable state is needed; the tier configuration is a compile-time constant. Using a `GenServer` to organize these computations forces all pricing lookups—which occur on every product page load and every cart update—to queue through one process.

## Code

```elixir
defmodule Commerce.PricingEngine do
  use GenServer

  @moduledoc """
  Computes unit prices, bulk discounts, and tiered pricing for catalog products.
  Used by the storefront, cart service, and B2B quote generator.
  """

  @default_tiers [
    %{min_qty: 1,    max_qty: 9,    discount: 0.00},
    %{min_qty: 10,   max_qty: 49,   discount: 0.05},
    %{min_qty: 50,   max_qty: 99,   discount: 0.10},
    %{min_qty: 100,  max_qty: 499,  discount: 0.15},
    %{min_qty: 500,  max_qty: nil,  discount: 0.20}
  ]

  @markup_targets %{
    "electronics"  => 0.30,
    "apparel"      => 0.50,
    "books"        => 0.40,
    "food"         => 0.25,
    "hardware"     => 0.35,
    "default"      => 0.40
  }

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because PricingEngine uses a GenServer purely as
  # VALIDATION: an organizational wrapper for pricing formulas. The state holds
  # VALIDATION: @default_tiers, a constant that never changes at runtime and could
  # VALIDATION: be a module attribute. All four operations are pure arithmetic on
  # VALIDATION: their arguments. Product page loads and cart updates that call
  # VALIDATION: these functions concurrently will serialize through one process,
  # VALIDATION: reducing throughput with no architectural benefit whatsoever.

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, @default_tiers, opts)
  end

  @doc """
  Returns the final unit price for a single unit of a product.
  `product` must have `:base_price` and optionally `:custom_tiers`.
  """
  def unit_price(pid, product, opts \\ []) do
    GenServer.call(pid, {:unit_price, product, opts})
  end

  @doc """
  Returns the total price for a bulk purchase of `quantity` units.
  """
  def bulk_price(pid, product, quantity) do
    GenServer.call(pid, {:bulk_price, product, quantity})
  end

  @doc """
  Returns the applicable per-unit price for `quantity` after tiered discounts.
  """
  def tiered_price(pid, product, quantity) do
    GenServer.call(pid, {:tiered_price, product, quantity})
  end

  @doc """
  Returns the gross margin percentage given a product's cost and computed price.
  """
  def margin(pid, product, quantity \\ 1) do
    GenServer.call(pid, {:margin, product, quantity})
  end

  ## GenServer Callbacks

  @impl true
  def init(tiers), do: {:ok, tiers}

  @impl true
  def handle_call({:unit_price, product, opts}, _from, default_tiers) do
    customer_group = Keyword.get(opts, :customer_group, :retail)
    base = product.base_price
    adjustment = group_adjustment(customer_group)
    price = Float.round(base * (1 + adjustment), 2)
    {:reply, {:ok, price}, default_tiers}
  end

  @impl true
  def handle_call({:bulk_price, product, quantity}, _from, default_tiers) do
    tiers = Map.get(product, :custom_tiers, default_tiers)
    per_unit = apply_tier(product.base_price, quantity, tiers)
    total = Float.round(per_unit * quantity, 2)
    {:reply, {:ok, %{per_unit: per_unit, total: total, quantity: quantity}}, default_tiers}
  end

  @impl true
  def handle_call({:tiered_price, product, quantity}, _from, default_tiers) do
    tiers = Map.get(product, :custom_tiers, default_tiers)
    per_unit = apply_tier(product.base_price, quantity, tiers)
    {:reply, {:ok, per_unit}, default_tiers}
  end

  @impl true
  def handle_call({:margin, product, quantity}, _from, default_tiers) do
    tiers = Map.get(product, :custom_tiers, default_tiers)
    sell_price = apply_tier(product.base_price, quantity, tiers)
    cost = Map.get(product, :cost_price, product.base_price * 0.6)
    margin_pct = if sell_price > 0, do: (sell_price - cost) / sell_price, else: 0.0
    {:reply, {:ok, Float.round(margin_pct, 4)}, default_tiers}
  end

  # VALIDATION: SMELL END

  defp apply_tier(base_price, quantity, tiers) do
    tier = Enum.find(tiers, List.last(tiers), fn t ->
      quantity >= t.min_qty and (is_nil(t.max_qty) or quantity <= t.max_qty)
    end)

    discounted = base_price * (1 - tier.discount)
    Float.round(discounted, 2)
  end

  defp group_adjustment(:vip), do: -0.10
  defp group_adjustment(:wholesale), do: -0.15
  defp group_adjustment(:employee), do: -0.25
  defp group_adjustment(:retail), do: 0.0
  defp group_adjustment(_), do: 0.0

  def target_markup(category) do
    Map.get(@markup_targets, category, @markup_targets["default"])
  end
end
```
