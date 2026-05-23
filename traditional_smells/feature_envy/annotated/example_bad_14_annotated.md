# Annotated Example — Feature Envy

| Field                  | Value                                                                                     |
|------------------------|-------------------------------------------------------------------------------------------|
| **Smell name**         | Feature Envy                                                                              |
| **Smell location**     | `Inventory.PurchaseOrderService.build_product_reorder_entry/1`                            |
| **Affected function**  | `build_product_reorder_entry/1`                                                           |
| **Explanation**        | The function calls `Product.get!/1`, `Product.sku/1`, `Product.reorder_point/1`, `Product.reorder_quantity/1`, `Product.preferred_supplier/1`, `Product.lead_time_days/1`, `Product.unit_cost/1`, and `Product.storage_requirements/1`, while reading `product.name`, `product.category`, and `product.unit_of_measure`. `PurchaseOrderService` contributes only arithmetic (total cost, expected arrival). All domain logic belongs to `Product`, making this function a poor fit for its current module. |

```elixir
defmodule Inventory.PurchaseOrderService do
  @moduledoc """
  Manages purchase order creation, approval workflows, and fulfillment tracking.
  """

  alias Inventory.{Product, Supplier, PurchaseOrder, PurchaseOrderLine, StockLevel}
  require Logger

  @approval_threshold_usd 10_000

  def create_order(supplier_id, line_attrs) do
    with {:ok, supplier} <- Supplier.fetch(supplier_id),
         {:ok, lines} <- build_lines(line_attrs),
         {:ok, order} <- PurchaseOrder.create(supplier, lines) do
      maybe_flag_for_approval(order)
    end
  end

  def approve_order(order_id, approver_id) do
    with {:ok, order} <- PurchaseOrder.fetch(order_id),
         :ok <- validate_approval_authority(approver_id, order.total) do
      PurchaseOrder.update(order_id, %{status: :approved, approved_by: approver_id})
    end
  end

  def receive_order(order_id, received_lines) do
    with {:ok, _order} <- PurchaseOrder.fetch(order_id) do
      Enum.each(received_lines, fn line ->
        StockLevel.increment(line.product_id, line.received_qty)
      end)

      PurchaseOrder.update(order_id, %{status: :received, received_at: DateTime.utc_now()})
    end
  end

  def cancel_order(order_id, reason) do
    Logger.info("Cancelling PO #{order_id}: #{reason}")
    PurchaseOrder.update(order_id, %{status: :cancelled, cancel_reason: reason})
  end

  def list_pending_orders(supplier_id) do
    PurchaseOrder.list_by_supplier_and_status(supplier_id, :pending)
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because build_product_reorder_entry/1 operates almost entirely
  # VALIDATION: on the Product module. It calls Product.get!/1, Product.sku/1,
  # VALIDATION: Product.reorder_point/1, Product.reorder_quantity/1,
  # VALIDATION: Product.preferred_supplier/1, Product.lead_time_days/1,
  # VALIDATION: Product.unit_cost/1, and Product.storage_requirements/1, while also reading
  # VALIDATION: product.name, product.category, and product.unit_of_measure.
  # VALIDATION: PurchaseOrderService contributes only derived arithmetic (total_cost,
  # VALIDATION: expected_arrival); all domain data and behaviour originate from Product.
  def build_product_reorder_entry(product_id) do
    product = Product.get!(product_id)

    sku = Product.sku(product)
    reorder_point = Product.reorder_point(product)
    reorder_qty = Product.reorder_quantity(product)
    supplier = Product.preferred_supplier(product)
    lead_time = Product.lead_time_days(product)
    unit_cost = Product.unit_cost(product)
    storage_reqs = Product.storage_requirements(product)

    total_cost = reorder_qty * unit_cost
    expected_arrival = Date.add(Date.utc_today(), lead_time)

    needs_cold_storage = Map.get(storage_reqs, :temperature_controlled, false)
    hazmat = Map.get(storage_reqs, :hazmat, false)

    %{
      product_id: product.id,
      product_name: product.name,
      sku: sku,
      category: product.category,
      unit_of_measure: product.unit_of_measure,
      reorder_point: reorder_point,
      reorder_quantity: reorder_qty,
      unit_cost: unit_cost,
      total_cost: total_cost,
      preferred_supplier: supplier,
      lead_time_days: lead_time,
      expected_arrival: expected_arrival,
      requires_cold_storage: needs_cold_storage,
      is_hazmat: hazmat
    }
  end
  # VALIDATION: SMELL END

  defp build_lines(line_attrs) do
    lines = Enum.map(line_attrs, &PurchaseOrderLine.build/1)

    if Enum.any?(lines, &match?({:error, _}, &1)) do
      {:error, :invalid_lines}
    else
      {:ok, lines}
    end
  end

  defp maybe_flag_for_approval(order) do
    if order.total >= @approval_threshold_usd do
      PurchaseOrder.update(order.id, %{status: :pending_approval})
    else
      {:ok, order}
    end
  end

  defp validate_approval_authority(_approver_id, _total), do: :ok
end
```
