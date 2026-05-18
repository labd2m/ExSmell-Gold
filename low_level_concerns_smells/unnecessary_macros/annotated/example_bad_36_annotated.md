# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Inventory.ReorderPolicy` module, `reorder_needed?/2` macro |
| **Affected function(s)** | `reorder_needed?/2` |
| **Short explanation** | `reorder_needed?/2` compares two integer quantities at runtime to decide whether a reorder should be triggered. This is a simple boolean expression that belongs in a regular function; wrapping it in a macro adds complexity with no benefit. |

```elixir
defmodule Inventory.ReorderPolicy do
  @moduledoc """
  Evaluates inventory levels against configured thresholds to determine
  when purchase orders should be automatically triggered.
  """

  @safety_stock_multiplier 1.2
  @default_lead_time_days 7

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `reorder_needed?/2` simply compares
  # two integer values at runtime. The boolean expression `current_qty <= threshold`
  # could be written inline or, at most, extracted into a plain function.
  # Using a macro forces all callers to `require` the module and introduces
  # needless `quote/unquote` indirection with zero compile-time benefit.
  defmacro reorder_needed?(current_qty, threshold) do
    quote do
      qty = unquote(current_qty)
      thr = unquote(threshold)
      qty <= thr
    end
  end
  # VALIDATION: SMELL END

  def compute_threshold(avg_daily_sales, lead_time_days \\ @default_lead_time_days) do
    base = avg_daily_sales * lead_time_days
    round(base * @safety_stock_multiplier)
  end

  def analyse_sku(sku_data) do
    require Inventory.ReorderPolicy

    threshold = compute_threshold(sku_data.avg_daily_sales, sku_data.lead_time_days)

    %{
      sku: sku_data.sku,
      current_qty: sku_data.current_qty,
      threshold: threshold,
      reorder_needed: Inventory.ReorderPolicy.reorder_needed?(sku_data.current_qty, threshold),
      suggested_order_qty: suggested_order(sku_data)
    }
  end

  def suggested_order(sku_data) do
    max_stock = sku_data.avg_daily_sales * sku_data.max_coverage_days
    gap = max_stock - sku_data.current_qty
    max(round(gap), 0)
  end

  def analyse_all(sku_list) do
    require Inventory.ReorderPolicy

    sku_list
    |> Enum.map(&analyse_sku/1)
    |> Enum.sort_by(fn s -> s.current_qty / max(s.threshold, 1) end)
  end

  def critical_skus(sku_list) do
    require Inventory.ReorderPolicy

    Enum.filter(sku_list, fn sku ->
      threshold = compute_threshold(sku.avg_daily_sales)
      Inventory.ReorderPolicy.reorder_needed?(sku.current_qty, threshold) and
        sku.current_qty <= threshold * 0.5
    end)
  end

  def generate_purchase_orders(sku_list, supplier_map) do
    sku_list
    |> analyse_all()
    |> Enum.filter(& &1.reorder_needed)
    |> Enum.map(fn analysis ->
      supplier = Map.get(supplier_map, analysis.sku, %{name: "unknown", lead_time: 7})

      %{
        sku: analysis.sku,
        qty: analysis.suggested_order_qty,
        supplier: supplier.name,
        expected_arrival: Date.add(Date.utc_today(), supplier.lead_time)
      }
    end)
  end

  def stock_coverage_days(current_qty, avg_daily_sales) when avg_daily_sales > 0 do
    Float.round(current_qty / avg_daily_sales, 1)
  end

  def stock_coverage_days(_, _), do: :infinity
end
```
