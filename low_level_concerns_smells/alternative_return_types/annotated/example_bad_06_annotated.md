# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Inventory.StockQuery.fetch/2`
- **Affected function(s):** `fetch/2`
- **Short explanation:** The `:aggregate` option changes the return from a list of `%StockEntry{}` structs, to a single integer count, to a keyword list of totals per warehouse. Each return type is used differently, and callers must track the option to handle results safely.

---

```elixir
defmodule MyApp.Inventory.StockQuery do
  @moduledoc """
  Queries current stock levels across warehouses and product variants.
  Supports low-stock alerting, reorder calculations, and inventory
  auditing workflows.
  """

  alias MyApp.Repo
  alias MyApp.Inventory.StockEntry
  alias MyApp.Inventory.Warehouse

  @low_stock_threshold 10
  @critical_stock_threshold 3

  def new_entry(product_id, warehouse_id, quantity) do
    %StockEntry{
      product_id: product_id,
      warehouse_id: warehouse_id,
      quantity: quantity,
      updated_at: DateTime.utc_now()
    }
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:aggregate] completely changes what
  # the function returns. :none returns a list of %StockEntry{} structs,
  # :total returns a plain integer (the summed quantity), and :by_warehouse
  # returns a keyword list of {warehouse_id, quantity} pairs. Each consumer
  # receives an incompatible type with no indication from the function signature.
  def fetch(product_id, opts \\ []) when is_list(opts) do
    aggregate = Keyword.get(opts, :aggregate, :none)
    only_available = Keyword.get(opts, :only_available, true)
    warehouse_ids = Keyword.get(opts, :warehouse_ids, :all)

    base_query =
      StockEntry
      |> StockEntry.for_product(product_id)
      |> then(fn q ->
        if only_available, do: StockEntry.with_positive_quantity(q), else: q
      end)
      |> then(fn q ->
        case warehouse_ids do
          :all -> q
          ids when is_list(ids) -> StockEntry.in_warehouses(q, ids)
        end
      end)

    entries = Repo.all(base_query)

    case aggregate do
      :none ->
        entries

      :total ->
        Enum.reduce(entries, 0, fn entry, acc -> acc + entry.quantity end)

      :by_warehouse ->
        entries
        |> Enum.group_by(& &1.warehouse_id)
        |> Enum.map(fn {wh_id, wh_entries} ->
          total = Enum.sum(Enum.map(wh_entries, & &1.quantity))
          {wh_id, total}
        end)
    end
  end
  # VALIDATION: SMELL END

  def low_stock_products(warehouse_id \\ :all) do
    warehouse_ids = if warehouse_id == :all, do: :all, else: [warehouse_id]

    StockEntry
    |> StockEntry.below_threshold(@low_stock_threshold)
    |> then(fn q ->
      case warehouse_ids do
        :all -> q
        ids -> StockEntry.in_warehouses(q, ids)
      end
    end)
    |> Repo.all()
    |> Enum.map(& &1.product_id)
    |> Enum.uniq()
  end

  def critical_stock?(product_id) do
    total = fetch(product_id, aggregate: :total)
    total <= @critical_stock_threshold
  end

  def reorder_needed?(product_id, reorder_point) do
    total = fetch(product_id, aggregate: :total)
    total < reorder_point
  end

  def warehouses_with_stock(product_id) do
    fetch(product_id, aggregate: :by_warehouse)
    |> Enum.filter(fn {_wh, qty} -> qty > 0 end)
    |> Keyword.keys()
  end

  def available_warehouses do
    Repo.all(Warehouse)
    |> Enum.filter(& &1.active)
    |> Enum.map(&{&1.id, &1.name})
  end
end
```
