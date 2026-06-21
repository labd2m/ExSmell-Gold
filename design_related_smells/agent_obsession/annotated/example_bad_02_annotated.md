# Annotated Example 02 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `CartSession`, `DiscountEngine`, `CheckoutService`, and `OrderSummary` all interact directly with the Agent PID
- **Affected functions:** `CartSession.add_item/3`, `DiscountEngine.apply_coupon/3`, `CheckoutService.finalize/2`, `OrderSummary.build/1`
- **Short explanation:** The responsibility for interacting with the Agent is scattered across four modules, each pushing its own data shape (map, keyword list, tuple, atom) into the shared state. There is no single owner of the Agent, leading to a fragile and difficult-to-maintain shared state.

---

```elixir
defmodule CartSession do
  @moduledoc """
  Manages a shopping cart session for a customer.
  """

  def new do
    Agent.start_link(fn -> %{items: [], meta: %{}} end)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because CartSession directly calls Agent.update/2
  # to manipulate the shared cart state, adding items in its own format.
  # No centralized interface controls access to the Agent.
  def add_item(pid, sku, quantity) do
    Agent.update(pid, fn state ->
      item = %{sku: sku, quantity: quantity, added_at: DateTime.utc_now()}
      Map.update!(state, :items, fn items -> [item | items] end)
    end)
  end
  # VALIDATION: SMELL END

  def get_items(pid) do
    Agent.get(pid, fn state -> state.items end)
  end

  def item_count(pid) do
    Agent.get(pid, fn state -> length(state.items) end)
  end
end

defmodule DiscountEngine do
  @moduledoc """
  Applies discount coupons and promotional rules to a cart.
  """

  @valid_coupons %{"SAVE10" => 0.10, "SAVE20" => 0.20, "FREESHIP" => 0.0}

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because DiscountEngine bypasses any cart
  # abstraction and writes directly to the Agent using Agent.update/2,
  # injecting coupon data under a key the cart owner did not anticipate.
  def apply_coupon(pid, code, customer_id) do
    case Map.fetch(@valid_coupons, code) do
      {:ok, rate} ->
        Agent.update(pid, fn state ->
          discount = %{code: code, rate: rate, applied_by: customer_id}
          put_in(state, [:meta, :discount], discount)
        end)
        {:ok, rate}
      :error ->
        {:error, :invalid_coupon}
    end
  end
  # VALIDATION: SMELL END

  def discount_rate(pid) do
    Agent.get(pid, fn state ->
      get_in(state, [:meta, :discount, :rate]) || 0.0
    end)
  end
end

defmodule CheckoutService do
  @moduledoc """
  Finalizes the checkout process and records order status.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because CheckoutService also directly calls
  # Agent.update/2, writing a completely different nested structure
  # (checkout result info) into the same shared Agent state — there is no
  # encapsulation of what the Agent is allowed to contain.
  def finalize(pid, payment_method) do
    items = Agent.get(pid, fn state -> state.items end)

    if Enum.empty?(items) do
      {:error, :empty_cart}
    else
      Agent.update(pid, fn state ->
        checkout_info = %{
          status: :completed,
          payment_method: payment_method,
          finalized_at: DateTime.utc_now()
        }
        put_in(state, [:meta, :checkout], checkout_info)
      end)
      {:ok, :order_placed}
    end
  end
  # VALIDATION: SMELL END

  def order_status(pid) do
    Agent.get(pid, fn state ->
      get_in(state, [:meta, :checkout, :status]) || :pending
    end)
  end
end

defmodule OrderSummary do
  @moduledoc """
  Builds a display summary of the current cart and order state.
  """

  def build(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because OrderSummary directly reads the
    # entire Agent state with Agent.get/2 and must know the internal structure
    # written by three other modules — coupling it tightly to their
    # implementation details.
    state = Agent.get(pid, fn s -> s end)
    # VALIDATION: SMELL END

    discount_rate = get_in(state, [:meta, :discount, :rate]) || 0.0
    checkout = get_in(state, [:meta, :checkout]) || %{}

    subtotal =
      state.items
      |> Enum.reduce(0, fn %{quantity: q}, acc -> acc + q end)

    %{
      item_count: length(state.items),
      subtotal_units: subtotal,
      discount_applied: discount_rate > 0,
      discount_rate: discount_rate,
      order_status: Map.get(checkout, :status, :pending),
      payment_method: Map.get(checkout, :payment_method)
    }
  end
end
```
