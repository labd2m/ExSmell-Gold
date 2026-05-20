# Annotated Example — Bad Code

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `fulfill/1` function, multi-clause heads
- **Affected function(s):** `fulfill/1`
- **Short explanation:** Each clause head extracts `state`, `item_count`, `order_id`, `customer_id`, `shipping_address`, `total_value`, and `channel` from `%Order{}`. Only `state` (pattern matched) and `item_count` (used in guards) control clause selection. The other five fields are body-only bindings that appear in all clause heads, creating a deceptive symmetry between dispatch-driving and body-only extractions.

```elixir
defmodule Fulfillment.OrderFulfiller do
  @moduledoc """
  Drives the order fulfillment lifecycle from confirmed through
  shipped state, handling split shipments, fraud holds, and VIP routing.
  """

  alias Fulfillment.{Order, WarehousePicker, ShippingCarrier, FraudHold}
  alias Fulfillment.{FulfillmentLog, CustomerNotifier, SplitShipmentPlanner}

  @bulk_order_threshold 20
  @large_order_threshold 5

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `order_id`, `customer_id`,
  # `shipping_address`, `total_value`, and `channel` are extracted in every
  # clause head even though they do not appear in any guard expression or
  # structural pattern. Only `state` (literal match) and `item_count` (guard
  # comparison) determine which clause is chosen. The surplus bindings blur
  # the boundary between dispatch conditions and incidental body variables,
  # and the smell worsens the more clauses and fields are added.

  def fulfill(%Order{
        state: :confirmed,
        item_count: item_count,
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: shipping_address,
        total_value: total_value,
        channel: channel
      })
      when item_count > @bulk_order_threshold do
    plan = SplitShipmentPlanner.plan(order_id, item_count, shipping_address)

    Enum.each(plan.shipments, fn shipment ->
      WarehousePicker.pick(shipment, shipping_address)
      ShippingCarrier.book(shipment, shipping_address, channel)
    end)

    FulfillmentLog.record(order_id, customer_id, :split_shipped, total_value)
    CustomerNotifier.notify_split_shipment(customer_id, order_id, plan.shipments)
    {:ok, :split_shipment, plan}
  end

  def fulfill(%Order{
        state: :confirmed,
        item_count: item_count,
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: shipping_address,
        total_value: total_value,
        channel: channel
      })
      when item_count > @large_order_threshold and item_count <= @bulk_order_threshold do
    picker_ref = WarehousePicker.pick_all(order_id, item_count, shipping_address)
    carrier_ref = ShippingCarrier.book_standard(order_id, shipping_address, channel)

    FulfillmentLog.record(order_id, customer_id, :shipped_standard, total_value)
    CustomerNotifier.notify_shipped(customer_id, order_id, carrier_ref)
    {:ok, :shipped, carrier_ref, picker_ref}
  end

  def fulfill(%Order{
        state: :confirmed,
        item_count: item_count,
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: shipping_address,
        total_value: total_value,
        channel: channel
      })
      when item_count <= @large_order_threshold do
    _ = item_count
    picker_ref = WarehousePicker.pick_express(order_id, shipping_address)
    carrier_ref = ShippingCarrier.book_express(order_id, shipping_address, channel)

    FulfillmentLog.record(order_id, customer_id, :shipped_express, total_value)
    CustomerNotifier.notify_shipped(customer_id, order_id, carrier_ref)
    {:ok, :express_shipped, carrier_ref, picker_ref}
  end

  def fulfill(%Order{
        state: :fraud_hold,
        item_count: _item_count,
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: _shipping_address,
        total_value: total_value,
        channel: channel
      }) do
    FraudHold.escalate(order_id, customer_id, total_value, channel)
    FulfillmentLog.record(order_id, customer_id, :fraud_hold_escalated, total_value)
    CustomerNotifier.notify_fraud_hold(customer_id, order_id)
    {:error, :fraud_hold}
  end

  def fulfill(%Order{
        state: :cancelled,
        item_count: _item_count,
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: _shipping_address,
        total_value: total_value,
        channel: _channel
      }) do
    FulfillmentLog.record(order_id, customer_id, :fulfillment_skipped_cancelled, total_value)
    {:error, :order_cancelled}
  end

  # VALIDATION: SMELL END

  def fulfill(%Order{state: state, order_id: order_id}) do
    Logger.error("Unhandled fulfillment state #{state} for order #{order_id}")
    {:error, {:unknown_state, state}}
  end
end
```
