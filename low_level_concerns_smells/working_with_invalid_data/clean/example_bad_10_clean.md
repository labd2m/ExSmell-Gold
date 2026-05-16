# example_bad_10_clean

```elixir
defmodule Inventory.ReplenishmentManager do
  @moduledoc """
  Manages automatic stock replenishment by monitoring inventory levels,
  computing reorder quantities, and creating purchase orders with suppliers.
  """

  alias Inventory.StockLedger
  alias Inventory.PurchaseOrderClient
  alias Inventory.SupplierRegistry
  alias Inventory.AuditTrail

  @low_stock_threshold 20
  @critical_stock_threshold 5
  @default_lead_time_days 7

  def check_and_replenish(warehouse_id) do
    with {:ok, low_stock_items} <- StockLedger.fetch_below_threshold(warehouse_id, @low_stock_threshold),
         replenishment_results <- Enum.map(low_stock_items, &request_replenishment(&1, warehouse_id)) do
      successes = Enum.count(replenishment_results, &match?({:ok, _}, &1))
      failures = Enum.count(replenishment_results, &match?({:error, _}, &1))

      {:ok, %{processed: length(low_stock_items), succeeded: successes, failed: failures}}
    end
  end

  defp request_replenishment(product, warehouse_id) do
    reorder_quantity = Map.get(product, :reorder_quantity)

    with {:ok, supplier} <- SupplierRegistry.preferred_for(product.sku),
         {:ok, po} <- build_purchase_order(product, supplier, reorder_quantity),
         {:ok, po_ref} <- PurchaseOrderClient.create(supplier, po),
         :ok <- AuditTrail.log_replenishment(warehouse_id, product.sku, po_ref, reorder_quantity) do
      {:ok, %{sku: product.sku, po_ref: po_ref, quantity: reorder_quantity}}
    end
  end

  defp build_purchase_order(product, supplier, quantity) do
    urgency = if product.current_stock <= @critical_stock_threshold, do: :urgent, else: :standard
    lead_time = Map.get(supplier, :lead_time_days, @default_lead_time_days)

    po = %{
      sku: product.sku,
      product_name: product.name,
      quantity: quantity,
      unit_cost: product.unit_cost,
      total_cost: product.unit_cost * quantity,
      supplier_id: supplier.id,
      urgency: urgency,
      expected_arrival_date: Date.add(Date.utc_today(), lead_time),
      warehouse_destination: product.warehouse_id,
      notes: build_notes(product, urgency)
    }

    {:ok, po}
  end

  defp build_notes(product, :urgent),
    do: "URGENT: SKU #{product.sku} critically low (#{product.current_stock} units remaining)."

  defp build_notes(product, :standard),
    do: "Routine reorder for SKU #{product.sku}."
end
```
