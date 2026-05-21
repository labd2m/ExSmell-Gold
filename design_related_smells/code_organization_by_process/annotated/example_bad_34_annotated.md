# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `DiscountEngine` module — entire GenServer structure |
| **Affected function(s)** | `apply_discounts/2`, `eligible_promotions/2`, `best_discount/2` |
| **Short explanation** | Discount calculation is a pure function of cart data and a static set of promotion rules. No mutable state is required between calls, no external resource is locked, and no scheduling is needed. Placing these rules inside a GenServer imposes unnecessary serialisation with no runtime advantage. |

```elixir
defmodule Commerce.DiscountEngine do
  use GenServer

  @moduledoc """
  Evaluates promotional discount rules against a shopping cart to
  determine applicable savings. Used at checkout before payment capture.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because the module is a pure rule evaluator —
  # it takes a cart map, evaluates static conditions, and returns discount
  # amounts. Nothing about this computation requires a process. The GenServer
  # adds latency (message passing, scheduling) and limits throughput by
  # serialising concurrent discount evaluations.

  @promotions [
    %{
      id:          :promo_bulk_10,
      description: "10% off orders over $100",
      condition:   fn cart -> cart.subtotal >= 100.0 end,
      discount:    fn cart -> cart.subtotal * 0.10 end
    },
    %{
      id:          :promo_bulk_20,
      description: "20% off orders over $250",
      condition:   fn cart -> cart.subtotal >= 250.0 end,
      discount:    fn cart -> cart.subtotal * 0.20 end
    },
    %{
      id:          :promo_free_shipping,
      description: "Free shipping on orders over $75",
      condition:   fn cart -> cart.subtotal >= 75.0 end,
      discount:    fn cart -> cart.shipping_cost end
    },
    %{
      id:          :promo_loyalty_5,
      description: "5% loyalty discount for members",
      condition:   fn cart -> cart.customer_tier in [:silver, :gold, :platinum] end,
      discount:    fn cart -> cart.subtotal * 0.05 end
    },
    %{
      id:          :promo_loyalty_10,
      description: "10% loyalty discount for gold/platinum members",
      condition:   fn cart -> cart.customer_tier in [:gold, :platinum] end,
      discount:    fn cart -> cart.subtotal * 0.10 end
    },
    %{
      id:          :promo_first_order,
      description: "15% off first order",
      condition:   fn cart -> cart.order_count == 0 end,
      discount:    fn cart -> cart.subtotal * 0.15 end
    }
  ]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Applies all eligible discounts to `cart` and returns
  `{:ok, %{discounts: list, total_discount: float, final_total: float}}`.
  """
  def apply_discounts(pid, cart) do
    GenServer.call(pid, {:apply_discounts, cart})
  end

  @doc "Returns a list of promotions that are eligible for the given cart."
  def eligible_promotions(pid, cart) do
    GenServer.call(pid, {:eligible_promotions, cart})
  end

  @doc "Returns the single best (highest value) discount promotion for the cart."
  def best_discount(pid, cart) do
    GenServer.call(pid, {:best_discount, cart})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:eligible_promotions, cart}, _from, state) do
    eligible = Enum.filter(@promotions, fn promo -> promo.condition.(cart) end)
    {:reply, {:ok, eligible}, state}
  end

  def handle_call({:apply_discounts, cart}, _from, state) do
    applied =
      Enum.filter(@promotions, fn p -> p.condition.(cart) end)
      |> Enum.map(fn p ->
        %{id: p.id, description: p.description, amount: Float.round(p.discount.(cart), 2)}
      end)

    total_discount = Enum.reduce(applied, 0.0, fn d, acc -> acc + d.amount end)
    final_total    = Float.round(cart.subtotal + cart.shipping_cost - total_discount, 2)

    result = %{
      discounts:      applied,
      total_discount: Float.round(total_discount, 2),
      final_total:    max(final_total, 0.0)
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:best_discount, cart}, _from, state) do
    eligible = Enum.filter(@promotions, fn p -> p.condition.(cart) end)

    result =
      case eligible do
        [] ->
          {:ok, nil}

        promos ->
          best =
            Enum.max_by(promos, fn p -> p.discount.(cart) end)

          {:ok, %{id: best.id, description: best.description, amount: Float.round(best.discount.(cart), 2)}}
      end

    {:reply, result, state}
  end

  # VALIDATION: SMELL END
end
```
