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

  def get_items(pid) do
    Agent.get(pid, fn state -> state.items end)
  end

  def add_item(pid, item) do
    Agent.update(pid, fn state ->
      %{state | items: [item | state.items]}
    end)
  end

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
end

defmodule OrderFinalizer do
  @moduledoc """
  Converts a confirmed cart session into a finalized order record.
  """

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

  defp generate_order_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
