# Annotated Example 10 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                             |
|------------------------|---------------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                                    |
| **Expected location**  | `Orders.FulfillmentCoordinator.fulfill/1`                                                        |
| **Affected function**  | `fulfill/1`                                                                                       |
| **Short explanation**  | The function head of each clause extracts `order_state` (clause selection) and `item_count` (guard), alongside `order_id`, `customer_id`, `shipping_address`, `line_items`, and `channel` — five fields that only appear inside the function bodies. Across four clauses, every head carries seven bindings, but only two of them meaningfully communicate the dispatch rules. This mixes signal and noise in a way that degrades readability proportionally to the number of clauses and extractions. |

---

```elixir
defmodule Orders.FulfillmentCoordinator do
  @moduledoc """
  Coordinates the fulfillment lifecycle for customer orders.
  Handles standard fulfillment, split-shipment logic for large orders,
  backorder queuing, and cancellation teardown.
  """

  require Logger

  alias Orders.{
    WarehousePicker,
    ShipmentBuilder,
    BackorderQueue,
    CancellationHandler,
    CustomerNotifier,
    FulfillmentLedger,
    AuditLog
  }

  @split_shipment_threshold 20
  @max_backorder_days 30

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `order_id`, `customer_id`,
  # `shipping_address`, `line_items`, and `channel` are extracted in all four
  # clause heads even though they never appear in a guard or influence which
  # clause is selected. Only `order_state` (matched as a literal atom) controls
  # dispatch, and only `item_count` is used in the guards. Reading through four
  # clauses with seven extractions each, the two dispatch-relevant bindings are
  # buried among five body-only bindings, substantially impairing the
  # readability of the routing logic.
  def fulfill(%Orders.Order{
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: shipping_address,
        line_items: line_items,
        channel: channel,
        order_state: :confirmed,
        item_count: item_count
      })
      when item_count <= @split_shipment_threshold do
    Logger.info("[FulfillmentCoordinator] Fulfilling order #{order_id} (#{item_count} items) via #{channel}")

    with {:ok, pick_list} <- WarehousePicker.generate_pick_list(order_id, line_items),
         {:ok, shipment} <- ShipmentBuilder.build_single(order_id, pick_list, shipping_address),
         {:ok, tracking_number} <- ShipmentBuilder.dispatch(shipment),
         :ok <- FulfillmentLedger.record(order_id, :fulfilled, %{
                  shipment_id: shipment.id,
                  tracking_number: tracking_number
                }),
         :ok <- CustomerNotifier.send_shipment_confirmation(customer_id, order_id, tracking_number, channel),
         :ok <- AuditLog.write(:order_fulfilled, customer_id, %{
                  order_id: order_id,
                  item_count: item_count,
                  tracking_number: tracking_number
                }) do
      Logger.info("[FulfillmentCoordinator] Order #{order_id} dispatched: #{tracking_number}")
      {:ok, :fulfilled, tracking_number}
    else
      {:error, :out_of_stock} = err ->
        Logger.warning("[FulfillmentCoordinator] Out of stock for order #{order_id}. Moving to backorder.")
        BackorderQueue.enqueue(order_id, @max_backorder_days)
        err

      {:error, reason} ->
        Logger.error("[FulfillmentCoordinator] Fulfillment failed for #{order_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def fulfill(%Orders.Order{
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: shipping_address,
        line_items: line_items,
        channel: channel,
        order_state: :confirmed,
        item_count: item_count
      })
      when item_count > @split_shipment_threshold do
    Logger.info(
      "[FulfillmentCoordinator] Large order #{order_id} (#{item_count} items). " <>
        "Initiating split-shipment fulfillment."
    )

    batches = Enum.chunk_every(line_items, @split_shipment_threshold)

    results =
      batches
      |> Enum.with_index(1)
      |> Enum.map(fn {batch, idx} ->
        with {:ok, pick_list} <- WarehousePicker.generate_pick_list(order_id, batch),
             {:ok, shipment} <- ShipmentBuilder.build_partial(order_id, pick_list, shipping_address, idx),
             {:ok, tracking} <- ShipmentBuilder.dispatch(shipment) do
          {:ok, tracking}
        else
          err -> err
        end
      end)

    tracking_numbers = for {:ok, t} <- results, do: t
    errors = for {:error, _} = e <- results, do: e

    :ok = FulfillmentLedger.record(order_id, :split_fulfilled, %{
      shipment_count: length(batches),
      tracking_numbers: tracking_numbers
    })

    :ok = CustomerNotifier.send_split_shipment_notice(customer_id, order_id, tracking_numbers, channel)

    :ok = AuditLog.write(:order_split_fulfilled, customer_id, %{
      order_id: order_id,
      item_count: item_count,
      batches: length(batches),
      errors: length(errors)
    })

    if Enum.empty?(errors) do
      {:ok, :split_fulfilled, tracking_numbers}
    else
      {:partial, tracking_numbers, errors}
    end
  end

  def fulfill(%Orders.Order{
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: _shipping_address,
        line_items: line_items,
        channel: channel,
        order_state: :backordered,
        item_count: item_count
      })
      when item_count > 0 do
    Logger.info("[FulfillmentCoordinator] Attempting backorder fulfillment for #{order_id}")

    availability = WarehousePicker.check_availability(line_items)

    if availability == :all_available do
      with {:ok, pick_list} <- WarehousePicker.generate_pick_list(order_id, line_items),
           {:ok, shipment} <- ShipmentBuilder.build_single(order_id, pick_list, _shipping_address = nil),
           {:ok, tracking} <- ShipmentBuilder.dispatch(shipment),
           :ok <- BackorderQueue.mark_fulfilled(order_id),
           :ok <- FulfillmentLedger.record(order_id, :backorder_fulfilled, %{tracking: tracking}),
           :ok <- CustomerNotifier.send_backorder_fulfilled_notice(customer_id, order_id, tracking, channel) do
        {:ok, :backorder_fulfilled, tracking}
      else
        {:error, reason} ->
          Logger.error("[FulfillmentCoordinator] Backorder fulfillment failed for #{order_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.info("[FulfillmentCoordinator] Backorder #{order_id} still has unavailable items")
      {:pending, :still_backordered}
    end
  end

  def fulfill(%Orders.Order{
        order_id: order_id,
        customer_id: customer_id,
        shipping_address: _shipping_address,
        line_items: line_items,
        channel: _channel,
        order_state: :cancellation_requested,
        item_count: item_count
      })
      when item_count >= 0 do
    Logger.info("[FulfillmentCoordinator] Processing cancellation for order #{order_id}")

    with :ok <- CancellationHandler.release_reservations(order_id, line_items),
         :ok <- CancellationHandler.issue_refund_if_charged(order_id),
         :ok <- FulfillmentLedger.record(order_id, :cancelled, %{item_count: item_count}),
         :ok <- CustomerNotifier.send_cancellation_confirmation(customer_id, order_id),
         :ok <- AuditLog.write(:order_cancelled, customer_id, %{order_id: order_id}) do
      {:ok, :cancelled, order_id}
    else
      {:error, reason} ->
        Logger.error("[FulfillmentCoordinator] Cancellation failed for #{order_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def fulfill(%Orders.Order{order_id: order_id, order_state: state}) do
    Logger.error("[FulfillmentCoordinator] No fulfillment handler for order state '#{state}' on #{order_id}")
    {:error, :unhandled_order_state}
  end
end
```
