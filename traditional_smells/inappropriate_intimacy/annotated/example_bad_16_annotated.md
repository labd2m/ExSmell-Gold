# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `FulfillmentCoordinator.fulfill/1` function
- **Affected function(s):** `FulfillmentCoordinator.fulfill/1`
- **Short explanation:** `FulfillmentCoordinator.fulfill/1` fetches a `SalesOrder` struct and a `Supplier` struct and then directly reads their internal fields (`.line_items`, `.priority_flag`, `.shipping_method`, `.lead_time_days`, `.dropship_enabled`, `.minimum_order_value`) to drive fulfillment decisions. All these details are internal to `SalesOrder` and `Supplier` and should be accessed through encapsulated queries rather than exposed as raw fields.

---

```elixir
defmodule MyApp.Fulfillment.FulfillmentCoordinator do
  @moduledoc """
  Coordinates the fulfillment pipeline for confirmed sales orders.
  Determines whether to fulfill from warehouse stock or route to a supplier.
  """

  alias MyApp.Sales.SalesOrder
  alias MyApp.Supply.Supplier
  alias MyApp.Inventory.{StockChecker, PickList}
  alias MyApp.Logistics.ShipmentRouter
  alias MyApp.Notifications.FulfillmentMailer

  def fulfill(order_id) do
    with {:ok, order} <- SalesOrder.fetch(order_id) do
      supplier = Supplier.primary_for_order(order)

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because fulfill/1 directly reads .line_items,
      # .priority_flag, and .shipping_method from the SalesOrder struct, and
      # .lead_time_days, .dropship_enabled, and .minimum_order_value from the Supplier
      # struct. These internal details should be queried through encapsulated functions
      # on SalesOrder and Supplier rather than accessed as raw struct fields here.
      line_items      = order.line_items
      is_priority     = order.priority_flag
      shipping_method = order.shipping_method

      lead_time       = supplier.lead_time_days
      can_dropship    = supplier.dropship_enabled
      min_order_value = supplier.minimum_order_value
      # VALIDATION: SMELL END

      order_value = Enum.reduce(line_items, 0.0, fn li, acc -> acc + li.unit_price * li.quantity end)

      all_in_stock = Enum.all?(line_items, fn li ->
        StockChecker.available?(li.product_id, li.quantity)
      end)

      cond do
        all_in_stock ->
          fulfill_from_warehouse(order, line_items, is_priority, shipping_method)

        can_dropship and order_value >= min_order_value ->
          route_to_dropship(order, supplier, line_items, lead_time)

        true ->
          {:error, :cannot_fulfill}
      end
    end
  end

  def mark_shipped(order_id, tracking_info) do
    case SalesOrder.fetch(order_id) do
      nil   -> {:error, :not_found}
      order ->
        updated = %{order | status: :shipped, tracking: tracking_info, shipped_at: DateTime.utc_now()}
        SalesOrder.save(updated)
        FulfillmentMailer.deliver_shipped_notice(updated)
        {:ok, updated}
    end
  end

  def hold(order_id, reason) do
    case SalesOrder.fetch(order_id) do
      nil   -> {:error, :not_found}
      %{status: :shipped} -> {:error, :already_shipped}
      order ->
        updated = %{order | status: :on_hold, hold_reason: reason}
        SalesOrder.save(updated)
        {:ok, updated}
    end
  end

  def release_hold(order_id) do
    case SalesOrder.fetch(order_id) do
      nil -> {:error, :not_found}
      %{status: :on_hold} = order ->
        fulfill(order_id)
      _ ->
        {:error, :not_on_hold}
    end
  end

  # --- Private helpers ---

  defp fulfill_from_warehouse(order, line_items, is_priority, shipping_method) do
    pick_list = PickList.create(order.id, line_items)
    PickList.queue(pick_list, priority: is_priority)
    ShipmentRouter.route(order.id, order.shipping_address, method: shipping_method)
    SalesOrder.update_status(order.id, :picking)
    {:ok, :warehouse_fulfillment_queued}
  end

  defp route_to_dropship(order, supplier, line_items, lead_time) do
    po = %{
      supplier_id: supplier.id,
      order_id:    order.id,
      line_items:  line_items,
      ship_to:     order.shipping_address,
      expected_by: DateTime.utc_now() |> DateTime.add(lead_time * 86_400, :second)
    }
    Supplier.submit_purchase_order(supplier.id, po)
    SalesOrder.update_status(order.id, :dropship_pending)
    {:ok, :dropship_order_submitted}
  end
end
```
