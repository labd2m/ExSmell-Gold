# Code Smell: Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `CartSession`, `CartCheckout`, `CartReporter`, and `CartNotifier`
- **Affected functions:** `CartSession.add_item/2`, `CartCheckout.apply_discount/2`, `CartReporter.summarize/1`, `CartNotifier.notify_abandoned/1`
- **Short explanation:** Direct `Agent` interactions (get/update) are scattered across four unrelated modules instead of being encapsulated in a single dedicated module. This spreads the responsibility for managing shared cart state, making it harder to maintain and introducing risk of inconsistent data formats.

---

```elixir
defmodule ShoppingCart.CartSession do
  @moduledoc """
  Handles cart session initialization and item additions.
  """

  def start() do
    Agent.start_link(fn -> %{items: [], discounts: [], metadata: %{}} end)
  end

  def add_item(pid, item) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because CartSession directly manipulates Agent state
    # instead of delegating to a dedicated Cart agent wrapper module.
    Agent.update(pid, fn state ->
      updated_items = [item | state.items]
      Map.put(state, :items, updated_items)
    end)
    # VALIDATION: SMELL END
  end

  def remove_item(pid, item_id) do
    Agent.update(pid, fn state ->
      updated_items = Enum.reject(state.items, fn i -> i.id == item_id end)
      Map.put(state, :items, updated_items)
    end)
  end

  def set_metadata(pid, key, value) do
    Agent.update(pid, fn state ->
      updated_meta = Map.put(state.metadata, key, value)
      Map.put(state, :metadata, updated_meta)
    end)
  end
end

defmodule ShoppingCart.CartCheckout do
  @moduledoc """
  Handles discount application and order finalization.
  """

  def apply_discount(pid, code) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because CartCheckout directly calls Agent.update/2,
    # spreading agent interaction responsibility outside the Cart abstraction layer.
    Agent.update(pid, fn state ->
      discount = %{code: code, applied_at: DateTime.utc_now()}
      Map.update(state, :discounts, [discount], fn existing -> [discount | existing] end)
    end)
    # VALIDATION: SMELL END
  end

  def finalize(pid) do
    Agent.get(pid, fn state ->
      total =
        Enum.reduce(state.items, 0.0, fn item, acc ->
          acc + item.price * item.quantity
        end)

      discount_amount =
        if length(state.discounts) > 0, do: total * 0.1, else: 0.0

      %{items: state.items, total: total, discount: discount_amount, net: total - discount_amount}
    end)
  end
end

defmodule ShoppingCart.CartReporter do
  @moduledoc """
  Generates reports and summaries of cart state.
  """

  def summarize(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because CartReporter directly reads from the Agent,
    # bypassing any centralized access control or data contract.
    Agent.get(pid, fn state ->
      item_count = length(state.items)
      discount_count = length(state.discounts)

      %{
        item_count: item_count,
        discount_count: discount_count,
        metadata: state.metadata
      }
    end)
    # VALIDATION: SMELL END
  end

  def export_csv(pid) do
    Agent.get(pid, fn state ->
      headers = "id,name,price,quantity\n"

      rows =
        Enum.map_join(state.items, "\n", fn item ->
          "#{item.id},#{item.name},#{item.price},#{item.quantity}"
        end)

      headers <> rows
    end)
  end
end

defmodule ShoppingCart.CartNotifier do
  @moduledoc """
  Sends notifications based on cart state.
  """

  def notify_abandoned(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because CartNotifier directly accesses Agent state
    # instead of going through a dedicated Cart module that owns the state contract.
    cart_data = Agent.get(pid, fn state -> state end)
    # VALIDATION: SMELL END

    if length(cart_data.items) > 0 do
      IO.puts("Sending abandoned cart notification for #{length(cart_data.items)} items")
      {:ok, :notified}
    else
      {:ok, :empty_cart}
    end
  end

  def notify_discount_expiry(pid, code) do
    Agent.get(pid, fn state ->
      Enum.any?(state.discounts, fn d -> d.code == code end)
    end)
    |> case do
      true -> IO.puts("Discount #{code} is about to expire in this cart")
      false -> IO.puts("Discount #{code} not found in cart")
    end
  end
end
```
