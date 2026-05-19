```elixir
defmodule WarehouseStock do
  @moduledoc """
  Initializes and provides base access to the warehouse stock Agent.
  """

  def start_link(initial_stock \\ %{}) do
    Agent.start_link(fn -> initial_stock end, name: __MODULE__)
  end

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
end

defmodule ReceivingDock do
  @moduledoc """
  Handles incoming stock from supplier deliveries.
  """

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
end

defmodule ShipmentPicker do
  @moduledoc """
  Fulfills outbound orders by reserving and decrementing stock.
  """

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
end
```
