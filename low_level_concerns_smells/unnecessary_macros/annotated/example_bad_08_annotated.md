# Annotated Example 08 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro clamp/3` inside `Inventory.StockUtils`
- **Affected function(s):** `clamp/3`
- **Short explanation:** The macro restricts a value to a [min, max] range using only `max/2` and `min/2` — trivial runtime arithmetic that needs no compile-time treatment. A regular function would be simpler and idiomatic.

---

```elixir
defmodule Inventory.StockUtils do
  @moduledoc """
  Utility helpers for stock level management, reorder calculations,
  and warehouse capacity enforcement.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because clamp/3 only calls max/2 and min/2 on
  # runtime numeric values. There is no compile-time transformation; a plain
  # function is cleaner, more testable, and equally performant.
  defmacro clamp(value, lower, upper) do
    quote do
      unquote(value)
      |> max(unquote(lower))
      |> min(unquote(upper))
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Computes the reorder quantity needed to bring stock up to the target level,
  capped by the warehouse's available receiving capacity.
  """
  @spec reorder_quantity(map()) :: non_neg_integer()
  def reorder_quantity(%{
        current_stock: current,
        target_level: target,
        max_receive_capacity: capacity
      }) do
    needed = max(target - current, 0)
    min(needed, capacity)
  end

  @doc """
  Determines whether a SKU is in a low-stock state.
  """
  @spec low_stock?(map()) :: boolean()
  def low_stock?(%{current_stock: current, reorder_point: reorder_point}) do
    current <= reorder_point
  end

  @doc """
  Returns the stock status atom for a given SKU record.
  """
  @spec stock_status(map()) :: :out_of_stock | :critical | :low | :healthy | :overstocked
  def stock_status(%{current_stock: current, max_capacity: max, reorder_point: rp, target: target}) do
    cond do
      current == 0 -> :out_of_stock
      current < rp / 2 -> :critical
      current <= rp -> :low
      current <= target -> :healthy
      current > max -> :overstocked
      true -> :healthy
    end
  end
end

defmodule Inventory.RestockService do
  @moduledoc """
  Handles automatic restock proposals for SKUs that have fallen below
  their reorder threshold. Integrates with the purchasing module to
  raise purchase orders.
  """

  require Inventory.StockUtils

  alias Inventory.StockUtils

  @min_reorder_units 1
  @max_reorder_units 10_000

  @doc """
  Generates restock proposals for a list of SKU records.
  Only includes SKUs that are in a low or critical state.
  """
  @spec generate_proposals(list(map())) :: list(map())
  def generate_proposals(skus) do
    skus
    |> Enum.filter(&StockUtils.low_stock?/1)
    |> Enum.map(fn sku ->
      raw_qty = StockUtils.reorder_quantity(sku)
      safe_qty = StockUtils.clamp(raw_qty, @min_reorder_units, @max_reorder_units)

      %{
        sku_id: sku.id,
        sku_code: sku.code,
        current_stock: sku.current_stock,
        proposed_quantity: safe_qty,
        status: StockUtils.stock_status(sku),
        raised_at: DateTime.utc_now()
      }
    end)
  end

  @doc """
  Filters proposals to only those exceeding a minimum order value threshold.
  """
  @spec filter_by_min_value(list(map()), list(map()), non_neg_integer()) :: list(map())
  def filter_by_min_value(proposals, sku_prices, min_value_cents) do
    price_index = Map.new(sku_prices, &{&1.sku_id, &1.unit_cost_cents})

    Enum.filter(proposals, fn proposal ->
      unit_cost = Map.get(price_index, proposal.sku_id, 0)
      proposal.proposed_quantity * unit_cost >= min_value_cents
    end)
  end

  @doc """
  Summarises restock proposals grouped by supplier.
  """
  @spec group_by_supplier(list(map()), list(map())) :: map()
  def group_by_supplier(proposals, sku_suppliers) do
    supplier_index = Map.new(sku_suppliers, &{&1.sku_id, &1.supplier_id})

    proposals
    |> Enum.group_by(fn p -> Map.get(supplier_index, p.sku_id, :unknown) end)
    |> Map.new(fn {supplier_id, props} ->
      {supplier_id, %{proposals: props, total_lines: length(props)}}
    end)
  end
end
```
