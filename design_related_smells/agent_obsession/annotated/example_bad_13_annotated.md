# Code Smell Example 13

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `WarehouseStock`, `ReceivingDock`, `ShipmentPicker`, and `StockAuditor`
- **Affected functions:** `WarehouseStock.adjust/3`, `ReceivingDock.receive_shipment/2`, `ShipmentPicker.pick/2`, `StockAuditor.discrepancies/2`
- **Short explanation:** The Agent holding warehouse stock levels is accessed directly in four separate modules. Each module independently reads and writes Agent state, making it impossible to centralize stock-level invariants (e.g., no negative stock) and leading to duplicated state-access patterns.

```elixir
defmodule WarehouseStock do
  @moduledoc """
  Initializes and provides base access to the warehouse stock Agent.
  """

  def start_link(initial_stock \\ %{}) do
    Agent.start_link(fn -> initial_stock end, name: __MODULE__)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because WarehouseStock directly writes to the Agent
  # and other modules also interact with the same Agent directly without going through
  # a centralized interface, spreading Agent responsibility across the system.
  def adjust(pid, sku, delta) do
    Agent.update(pid, fn stock ->
      current = Map.get(stock, sku, 0)
      Map.put(stock, sku, max(0, current + delta))
    end)
  end

  def level(pid, sku) do
    Agent.get(pid, fn stock -> Map.get(stock, sku, 0) end)
  end

  def snapshot(pid) do
    Agent.get(pid, fn stock -> stock end)
  end
  # VALIDATION: SMELL END
end

defmodule ReceivingDock do
  @moduledoc """
  Handles incoming stock from supplier deliveries.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because ReceivingDock directly calls Agent.update/2 on
  # the stock Agent to record received goods, instead of delegating to WarehouseStock.
  def receive_shipment(pid, line_items) do
    Enum.each(line_items, fn %{sku: sku, quantity: qty} ->
      Agent.update(pid, fn stock ->
        current = Map.get(stock, sku, 0)
        Map.put(stock, sku, current + qty)
      end)
    end)

    :ok
  end

  def log_discrepancy(sku, expected, actual) do
    IO.warn("Discrepancy for #{sku}: expected #{expected}, got #{actual}")
  end
  # VALIDATION: SMELL END
end

defmodule ShipmentPicker do
  @moduledoc """
  Fulfills outbound orders by reserving and decrementing stock.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because ShipmentPicker directly queries and mutates the
  # Agent state for stock picking, adding another independent Agent access point.
  def pick(pid, order_lines) do
    result =
      Agent.get_and_update(pid, fn stock ->
        Enum.reduce_while(order_lines, {[], stock}, fn %{sku: sku, qty: qty}, {picked, s} ->
          current = Map.get(s, sku, 0)

          if current >= qty do
            new_stock = Map.put(s, sku, current - qty)
            {:cont, {[{sku, qty} | picked], new_stock}}
          else
            {:halt, {{:error, {:insufficient_stock, sku}}, s}}
          end
        end)
        |> case do
          {{:error, _} = err, original} -> {err, original}
          {picked, updated} -> {{:ok, Enum.reverse(picked)}, updated}
        end
      end)

    result
  end
  # VALIDATION: SMELL END

  def build_pick_list(order_lines, stock_snapshot) do
    Enum.map(order_lines, fn %{sku: sku, qty: qty} ->
      available = Map.get(stock_snapshot, sku, 0)
      %{sku: sku, requested: qty, available: available, shortfall: max(0, qty - available)}
    end)
  end
end

defmodule StockAuditor do
  @moduledoc """
  Compares live Agent state against an expected inventory manifest.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because StockAuditor directly reads the Agent state to
  # perform an audit, instead of using a snapshot function from a central module.
  def discrepancies(pid, manifest) do
    Agent.get(pid, fn stock ->
      all_skus = Map.keys(stock) ++ Map.keys(manifest) |> Enum.uniq()

      Enum.flat_map(all_skus, fn sku ->
        live = Map.get(stock, sku, 0)
        expected = Map.get(manifest, sku, 0)

        if live != expected do
          [%{sku: sku, live: live, expected: expected, diff: live - expected}]
        else
          []
        end
      end)
    end)
  end

  def total_value(pid, price_list) do
    Agent.get(pid, fn stock ->
      Enum.reduce(stock, 0.0, fn {sku, qty}, acc ->
        price = Map.get(price_list, sku, 0.0)
        acc + qty * price
      end)
    end)
  end
  # VALIDATION: SMELL END
end
```
