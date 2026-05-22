```elixir
defmodule UnitConverter do
  @conversions %{
    kg:    1.0,
    g:     0.001,
    lb:    0.453_592,
    oz:    0.028_349_5,
    piece: 1.0,
    dozen: 12.0,
    box:   1.0,
    pallet: 1.0
  }

  def to_base_unit(amount, unit) do
    factor = Map.get(@conversions, unit, 1.0)
    Float.round(amount * factor, 6)
  end

  def from_base_unit(amount, unit) do
    factor = Map.get(@conversions, unit, 1.0)
    Float.round(amount / factor, 6)
  end

  def compatible?(unit_a, unit_b) do
    weight_units = [:kg, :g, :lb, :oz]
    count_units  = [:piece, :dozen, :box, :pallet]
    (unit_a in weight_units and unit_b in weight_units) or
    (unit_a in count_units  and unit_b in count_units)
  end
end

defmodule StockHelpers do
  defmacro __using__(_opts) do
    quote do
      import UnitConverter

      def available_stock(item) do
        item.on_hand - item.reserved
      end

      def days_of_supply(item) when item.avg_daily_demand > 0 do
        Float.round(available_stock(item) / item.avg_daily_demand, 1)
      end
      def days_of_supply(_), do: :infinity

      def safety_stock(item) do
        item.lead_time_days * item.avg_daily_demand * 1.5
      end

      def reorder_point(item) do
        item.lead_time_days * item.avg_daily_demand + safety_stock(item)
      end
    end
  end
end

defmodule InventoryManager do
  use StockHelpers

  @low_stock_threshold_days 7
  @overstock_threshold_days 90

  def reorder_needed?(%{unit: unit} = item) do
    base = to_base_unit(available_stock(item), unit)
    base <= reorder_point(item)
  end

  def restock_quantity(item, target_days) do
    target_units = item.avg_daily_demand * target_days
    deficit      = target_units - available_stock(item)
    raw          = max(deficit, 0.0)
    from_base_unit(raw, item.unit)
  end

  def valuation(items) do
    Enum.reduce(items, %{total: 0.0, by_category: %{}}, fn item, acc ->
      qty_base = to_base_unit(item.on_hand, item.unit)
      value    = Float.round(qty_base * item.unit_cost, 2)
      cat      = item.category

      %{
        acc |
        total:       acc.total + value,
        by_category: Map.update(acc.by_category, cat, value, &(&1 + value))
      }
    end)
  end

  def classify(item) do
    cond do
      days_of_supply(item) <= @low_stock_threshold_days  -> :critical
      reorder_needed?(item)                              -> :low
      days_of_supply(item) >= @overstock_threshold_days  -> :overstock
      true                                               -> :healthy
    end
  end

  def audit_report(items) do
    items
    |> Enum.map(fn item ->
      %{
        sku:         item.sku,
        description: item.description,
        on_hand:     item.on_hand,
        unit:        item.unit,
        available:   available_stock(item),
        dos:         days_of_supply(item),
        status:      classify(item),
        reorder_qty: restock_quantity(item, 30)
      }
    end)
    |> Enum.sort_by(& &1.dos)
  end

  def compatible_units?(item_a, item_b) do
    compatible?(item_a.unit, item_b.unit)
  end
end
```
