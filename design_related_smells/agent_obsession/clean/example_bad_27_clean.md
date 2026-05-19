```elixir
defmodule ShoppingCart.CartSession do
  @moduledoc """
  Handles cart session initialization and item additions.
  """

  def start() do
    Agent.start_link(fn -> %{items: [], discounts: [], metadata: %{}} end)
  end

  def add_item(pid, item) do
    Agent.update(pid, fn state ->
      updated_items = [item | state.items]
      Map.put(state, :items, updated_items)
    end)
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
    Agent.update(pid, fn state ->
      discount = %{code: code, applied_at: DateTime.utc_now()}
      Map.update(state, :discounts, [discount], fn existing -> [discount | existing] end)
    end)
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
    Agent.get(pid, fn state ->
      item_count = length(state.items)
      discount_count = length(state.discounts)

      %{
        item_count: item_count,
        discount_count: discount_count,
        metadata: state.metadata
      }
    end)
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
    cart_data = Agent.get(pid, fn state -> state end)

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
