# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `InventoryReceiver`, `InventoryPicker`, `InventoryAdjuster`, and `StockReporter`
- **Affected functions:** `InventoryReceiver.receive_goods/2`, `InventoryPicker.pick_items/3`, `InventoryAdjuster.adjust/3`, `StockReporter.low_stock/2`
- **Short explanation:** Four separate modules each read or write the stock Agent directly, spreading the internal stock map format across unrelated warehouse-domain concerns without any centralised owner.

```elixir
defmodule StockAgent do
  @moduledoc "Agent holding the warehouse stock levels and movement log."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn -> %{stock: %{}, movements: [], reserved: %{}} end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because InventoryReceiver directly calls Agent.update to
# increment stock quantities, taking ownership of the internal stock map without going
# through any single interface module.
defmodule InventoryReceiver do
  @moduledoc "Records incoming goods from suppliers."

  require Logger

  def receive_goods(agent, line_items) when is_list(line_items) do
    Agent.update(agent, fn state ->
      {new_stock, movements} =
        Enum.reduce(line_items, {state.stock, state.movements}, fn item, {stock, mvts} ->
          sku = item.sku
          qty = item.quantity

          updated_stock = Map.update(stock, sku, qty, &(&1 + qty))

          movement = %{
            type: :receipt,
            sku: sku,
            quantity: qty,
            reference: Map.get(item, :po_number),
            timestamp: DateTime.utc_now()
          }

          {updated_stock, [movement | mvts]}
        end)

      %{state | stock: new_stock, movements: movements}
    end)

    Logger.info("Received #{length(line_items)} line items into stock")
    :ok
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because InventoryPicker directly calls Agent.get and
# Agent.update to check availability and decrement stock, embedding state-mutation
# logic in a module whose concern should be order-picking, not Agent management.
defmodule InventoryPicker do
  @moduledoc "Fulfils pick requests for outbound orders."

  require Logger

  def pick_items(agent, order_id, line_items) do
    shortfalls =
      Agent.get(agent, fn state ->
        Enum.filter(line_items, fn item ->
          available = Map.get(state.stock, item.sku, 0)
          reserved = Map.get(state.reserved, item.sku, 0)
          available - reserved < item.quantity
        end)
      end)

    if shortfalls != [] do
      {:error, {:insufficient_stock, Enum.map(shortfalls, & &1.sku)}}
    else
      Agent.update(agent, fn state ->
        {new_stock, movements} =
          Enum.reduce(line_items, {state.stock, state.movements}, fn item, {stock, mvts} ->
            updated = Map.update!(stock, item.sku, &(&1 - item.quantity))
            movement = %{type: :pick, sku: item.sku, quantity: item.quantity, order_id: order_id, timestamp: DateTime.utc_now()}
            {updated, [movement | mvts]}
          end)

        %{state | stock: new_stock, movements: movements}
      end)

      Logger.info("Picked #{length(line_items)} lines for order #{order_id}")
      :ok
    end
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because InventoryAdjuster directly calls Agent.update to
# apply arbitrary stock corrections, another module assuming full knowledge of the
# Agent's internal structure to perform its adjustments.
defmodule InventoryAdjuster do
  @moduledoc "Applies manual stock corrections after cycle counts or damage."

  require Logger

  @valid_reasons [:damage, :cycle_count, :theft, :supplier_error, :system_correction]

  def adjust(agent, sku, delta, reason \\ :system_correction)

  def adjust(_agent, _sku, 0, _reason), do: :ok

  def adjust(agent, sku, delta, reason) when reason in @valid_reasons do
    Agent.update(agent, fn state ->
      current = Map.get(state.stock, sku, 0)
      new_qty = max(0, current + delta)

      movement = %{
        type: :adjustment,
        sku: sku,
        quantity: delta,
        reason: reason,
        previous_qty: current,
        new_qty: new_qty,
        timestamp: DateTime.utc_now()
      }

      Logger.info("Adjusted #{sku} by #{delta} (#{reason}): #{current} → #{new_qty}")

      %{state | stock: Map.put(state.stock, sku, new_qty), movements: [movement | state.movements]}
    end)

    :ok
  end

  def adjust(_agent, _sku, _delta, reason) do
    {:error, "Invalid adjustment reason: #{reason}"}
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because StockReporter directly calls Agent.get to read the
# raw stock map, coupling reporting logic to the Agent's internal data format.
defmodule StockReporter do
  @moduledoc "Provides stock-level queries and reports."

  def low_stock(agent, threshold \\ 10) do
    Agent.get(agent, fn state ->
      state.stock
      |> Enum.filter(fn {_sku, qty} -> qty <= threshold end)
      |> Enum.sort_by(fn {_sku, qty} -> qty end)
    end)
  end

  def movement_history(agent, sku) do
    Agent.get(agent, fn state ->
      Enum.filter(state.movements, &(&1.sku == sku))
    end)
  end

  def stock_value(agent, price_lookup) when is_function(price_lookup, 1) do
    Agent.get(agent, fn state ->
      Enum.reduce(state.stock, 0.0, fn {sku, qty}, acc ->
        price = price_lookup.(sku) || 0.0
        acc + qty * price
      end)
    end)
  end
end
# VALIDATION: SMELL END
```
