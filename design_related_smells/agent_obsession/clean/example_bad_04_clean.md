```elixir
defmodule WarehouseStock do
  @moduledoc """
  Tracks physical goods received at the warehouse.
  """

  def init do
    Agent.start_link(fn -> %{stock: %{}, movements: []} end)
  end

  def receive_goods(pid, sku, quantity) when quantity > 0 do
    Agent.update(pid, fn state ->
      updated_stock = Map.update(state.stock, sku, quantity, fn current -> current + quantity end)
      movement = %{type: :receipt, sku: sku, quantity: quantity, at: DateTime.utc_now()}
      %{state | stock: updated_stock, movements: [movement | state.movements]}
    end)
    :ok
  end

  def available(pid, sku) do
    Agent.get(pid, fn state -> Map.get(state.stock, sku, 0) end)
  end

  def all_stock(pid) do
    Agent.get(pid, fn state -> state.stock end)
  end
end

defmodule PurchaseOrderHandler do
  @moduledoc """
  Processes purchase orders and reserves inventory quantities.
  """

  def reserve(pid, order_id, line_items) do
    result =
      Agent.get_and_update(pid, fn state ->
        Enum.reduce_while(line_items, {:ok, state}, fn {sku, qty}, {:ok, acc} ->
          available = Map.get(acc.stock, sku, 0)
          if available >= qty do
            new_stock = Map.update!(acc.stock, sku, fn cur -> cur - qty end)
            movement = %{type: :reservation, order_id: order_id, sku: sku, quantity: qty, at: DateTime.utc_now()}
            new_state = %{acc | stock: new_stock, movements: [movement | acc.movements]}
            {:cont, {:ok, new_state}}
          else
            {:halt, {{:error, {:insufficient_stock, sku}}, acc}}
          end
        end)
        |> then(fn {status, new_state} -> {status, new_state} end)
      end)
    result
  end
end

defmodule PickListBuilder do
  @moduledoc """
  Builds pick lists for warehouse fulfillment operations.
  """

  def add_pick(pid, pick_id, items) do
    Agent.update(pid, fn state ->
      pick_entries = Enum.map(items, fn {sku, qty} ->
        %{type: :pick, pick_id: pick_id, sku: sku, quantity: qty, at: DateTime.utc_now()}
      end)
      %{state | movements: pick_entries ++ state.movements}
    end)
    :ok
  end

  def picks_for(pid, pick_id) do
    Agent.get(pid, fn state ->
      Enum.filter(state.movements, fn
        %{type: :pick, pick_id: ^pick_id} -> true
        _ -> false
      end)
    end)
  end
end

defmodule InventoryReporter do
  @moduledoc """
  Produces inventory snapshots and movement reports.
  """

  def snapshot(pid) do
    state = Agent.get(pid, fn s -> s end)

    receipts = Enum.filter(state.movements, &(&1.type == :receipt))
    reservations = Enum.filter(state.movements, &(&1.type == :reservation))
    picks = Enum.filter(state.movements, &(&1.type == :pick))

    %{
      current_stock: state.stock,
      total_received: Enum.reduce(receipts, 0, fn m, acc -> acc + m.quantity end),
      total_reserved: Enum.reduce(reservations, 0, fn m, acc -> acc + m.quantity end),
      total_picked: Enum.reduce(picks, 0, fn m, acc -> acc + m.quantity end),
      movement_count: length(state.movements)
    }
  end

  def low_stock_alert(pid, threshold) do
    Agent.get(pid, fn state ->
      state.stock
      |> Enum.filter(fn {_sku, qty} -> qty < threshold end)
      |> Enum.map(fn {sku, qty} -> {sku, qty} end)
    end)
  end
end
```
