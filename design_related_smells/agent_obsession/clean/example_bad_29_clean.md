```elixir
defmodule Inventory.InventoryWriter do
  @moduledoc """
  Handles stock updates and restocking operations.
  """

  def start_store() do
    Agent.start_link(fn -> %{stock: %{}, reserved: %{}, last_sync: nil} end)
  end

  def restock(pid, sku, quantity) do
    Agent.update(pid, fn state ->
      updated_stock = Map.update(state.stock, sku, quantity, &(&1 + quantity))
      %{state | stock: updated_stock}
    end)
  end

  def deduct(pid, sku, quantity) do
    Agent.update(pid, fn state ->
      current = Map.get(state.stock, sku, 0)
      new_qty = max(0, current - quantity)
      %{state | stock: Map.put(state.stock, sku, new_qty)}
    end)
  end

  def reserve(pid, sku, quantity) do
    Agent.update(pid, fn state ->
      updated_reserved = Map.update(state.reserved, sku, quantity, &(&1 + quantity))
      %{state | reserved: updated_reserved}
    end)
  end
end

defmodule Inventory.InventoryReader do
  @moduledoc """
  Provides read-only access to current stock levels.
  """

  def available_quantity(pid, sku) do
    Agent.get(pid, fn state ->
      stock_qty = Map.get(state.stock, sku, 0)
      reserved_qty = Map.get(state.reserved, sku, 0)
      max(0, stock_qty - reserved_qty)
    end)
  end

  def all_skus(pid) do
    Agent.get(pid, fn state -> Map.keys(state.stock) end)
  end

  def snapshot(pid) do
    Agent.get(pid, fn state -> state end)
  end
end

defmodule Inventory.InventoryAlerts do
  @moduledoc """
  Monitors stock levels and triggers low-stock alerts.
  """

  def check_low_stock(pid, threshold) do
    low_stock_items =
      Agent.get(pid, fn state ->
        Enum.filter(state.stock, fn {_sku, qty} -> qty < threshold end)
      end)

    Enum.each(low_stock_items, fn {sku, qty} ->
      IO.puts("LOW STOCK ALERT: #{sku} has only #{qty} units remaining")
    end)

    low_stock_items
  end

  def out_of_stock(pid) do
    Agent.get(pid, fn state ->
      Enum.filter(state.stock, fn {_sku, qty} -> qty == 0 end)
      |> Enum.map(fn {sku, _qty} -> sku end)
    end)
  end
end

defmodule Inventory.InventorySync do
  @moduledoc """
  Synchronizes inventory state with external warehouse data.
  """

  def sync_warehouse(pid, warehouse_data) do
    Agent.update(pid, fn state ->
      merged_stock =
        Enum.reduce(warehouse_data, state.stock, fn {sku, qty}, acc ->
          Map.put(acc, sku, qty)
        end)

      %{state | stock: merged_stock, last_sync: DateTime.utc_now()}
    end)
  end

  def last_sync_time(pid) do
    Agent.get(pid, fn state -> state.last_sync end)
  end
end
```
