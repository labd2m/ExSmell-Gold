# Code Smell Example 10

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `CartSession`, `InventoryChecker`, `PricingEngine`, and `OrderFinalizer`
- **Affected functions:** `CartSession.init/1`, `InventoryChecker.reserve_items/2`, `PricingEngine.apply_discount/2`, `OrderFinalizer.checkout/2`
- **Short explanation:** The responsibility for interacting directly with the Agent that holds cart state is spread across four unrelated modules. Each module calls `Agent.get/2` or `Agent.update/2` directly, rather than delegating all Agent interactions to a single owner module. This makes it hard to track state changes, reason about data shape, and maintain consistent cart logic.

```elixir
defmodule CartSession do
  @moduledoc """
  Starts and manages an agent-backed shopping cart session.
  """

  def init(user_id) do
    {:ok, pid} = Agent.start_link(fn ->
      %{
        user_id: user_id,
        items: [],
        discount: nil,
        reserved: false,
        total: 0.0
      }
    end)

    pid
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because CartSession directly interacts with the Agent
  # to read state, instead of centralizing all Agent access in one module.
  def get_items(pid) do
    Agent.get(pid, fn state -> state.items end)
  end

  def add_item(pid, item) do
    Agent.update(pid, fn state ->
      %{state | items: [item | state.items]}
    end)
  end
  # VALIDATION: SMELL END

  def session_info(pid) do
    Agent.get(pid, fn state -> Map.take(state, [:user_id, :reserved, :total]) end)
  end
end

defmodule InventoryChecker do
  @moduledoc """
  Verifies availability and reserves items for a cart session.
  """

  @inventory %{
    "SKU-001" => 10,
    "SKU-002" => 0,
    "SKU-003" => 5
  }

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because InventoryChecker directly accesses and mutates
  # the Agent state, spreading Agent interaction responsibility outside the owning module.
  def reserve_items(pid, _user_id) do
    items = Agent.get(pid, fn state -> state.items end)

    all_available =
      Enum.all?(items, fn %{sku: sku, qty: qty} ->
        Map.get(@inventory, sku, 0) >= qty
      end)

    if all_available do
      Agent.update(pid, fn state -> %{state | reserved: true} end)
      {:ok, :reserved}
    else
      {:error, :out_of_stock}
    end
  end
  # VALIDATION: SMELL END

  def check_sku(sku) do
    Map.get(@inventory, sku, 0)
  end
end

defmodule PricingEngine do
  @moduledoc """
  Applies discounts and recalculates cart totals.
  """

  @discounts %{
    "SAVE10" => 0.10,
    "SAVE20" => 0.20,
    "HALFOFF" => 0.50
  }

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because PricingEngine directly reads and writes the Agent
  # state to apply a discount, bypassing any centralized Agent ownership.
  def apply_discount(pid, code) do
    case Map.fetch(@discounts, code) do
      {:ok, rate} ->
        Agent.update(pid, fn state ->
          base_total =
            Enum.reduce(state.items, 0.0, fn %{price: p, qty: q}, acc -> acc + p * q end)

          discounted = base_total * (1 - rate)
          %{state | discount: code, total: Float.round(discounted, 2)}
        end)

        {:ok, rate}

      :error ->
        {:error, :invalid_code}
    end
  end

  def calculate_base_total(items) do
    Enum.reduce(items, 0.0, fn %{price: p, qty: q}, acc -> acc + p * q end)
  end
  # VALIDATION: SMELL END
end

defmodule OrderFinalizer do
  @moduledoc """
  Converts a confirmed cart session into a finalized order record.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because OrderFinalizer directly calls Agent.get/2
  # to read the full cart state, spreading Agent responsibility to yet another module.
  def checkout(pid, payment_method) do
    state = Agent.get(pid, fn s -> s end)

    unless state.reserved do
      {:error, :items_not_reserved}
    else
      order = %{
        order_id: generate_order_id(),
        user_id: state.user_id,
        items: state.items,
        discount: state.discount,
        total: state.total,
        payment_method: payment_method,
        placed_at: DateTime.utc_now()
      }

      Agent.update(pid, fn s -> Map.put(s, :finalized, true) end)

      {:ok, order}
    end
  end
  # VALIDATION: SMELL END

  defp generate_order_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
