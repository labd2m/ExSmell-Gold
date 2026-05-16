# Example 41: E-Commerce Order Fulfillment Service

```elixir
defmodule Ecommerce.FulfillmentService do
  @moduledoc """
  Manages order fulfillment, shipment creation, split-shipments,
  carrier selection, and delivery event tracking.
  """

  alias Ecommerce.{Order, Shipment, OrderLine, Carrier, Warehouse, TrackingEvent, Notification}

  @default_carrier :fedex
  @max_shipment_weight_kg 30

  def create_shipment(order_id, warehouse_id) do
    with {:ok, order} <- Order.get(order_id),
         {:ok, warehouse} <- Warehouse.get(warehouse_id),
         :ok <- validate_order_fulfillable(order),
         {:ok, carrier} <- select_carrier(order, warehouse),
         {:ok, rate} <- Carrier.get_shipping_rate(carrier, order, warehouse) do

      shipment = %Shipment{
        id: generate_shipment_id(),
        order_id: order_id,
        warehouse_id: warehouse_id,
        carrier: carrier,
        tracking_number: nil,
        status: :pending,
        shipping_cost: rate.cost,
        estimated_delivery: rate.estimated_delivery,
        line_items: order.line_items,
        created_at: DateTime.utc_now()
      }

      {:ok, _} = Shipment.insert(shipment)
      {:ok, _} = Order.update(order_id, %{status: :processing, shipment_id: shipment.id})
      {:ok, _} = Notification.send(order.customer_id, :shipment_created, shipment)

      {:ok, shipment}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def split_shipment(shipment_id, split_quantities, reason) do
    with {:ok, shipment} <- Shipment.get(shipment_id),
         :ok <- validate_shipment_splittable(shipment) do

      total_split = Enum.sum(Enum.map(split_quantities, & &1.quantity))
      original_total = Enum.sum(Enum.map(shipment.line_items, & &1.quantity))

      if total_split != original_total do
        {:error, :split_quantities_mismatch}
      else
        child_shipments =
          Enum.map(split_quantities, fn split ->
            line_items = Enum.filter(shipment.line_items, fn li ->
              split_entry = Enum.find(split_quantities, &(&1.line_item_id == li.id))
              split_entry != nil
            end)

            %Shipment{
              id: generate_shipment_id(),
              order_id: shipment.order_id,
              warehouse_id: shipment.warehouse_id,
              carrier: shipment.carrier,
              parent_shipment_id: shipment_id,
              status: :pending,
              line_items: line_items,
              split_reason: reason,
              created_at: DateTime.utc_now()
            }
          end)

        Enum.each(child_shipments, fn cs -> {:ok, _} = Shipment.insert(cs) end)
        {:ok, _} = Shipment.update(shipment_id, %{status: :split, split_into: Enum.map(child_shipments, & &1.id)})

        {:ok, child_shipments}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def confirm_shipment(shipment_id, tracking_number) do
    with {:ok, shipment} <- Shipment.get(shipment_id),
         :ok <- validate_shipment_confirmable(shipment) do

      {:ok, _} = Shipment.update(shipment_id, %{
        tracking_number: tracking_number,
        status: :confirmed,
        confirmed_at: DateTime.utc_now()
      })

      {:ok, order} = Order.get(shipment.order_id)
      {:ok, _} = Order.update(shipment.order_id, %{status: :shipped})
      {:ok, _} = Notification.send(order.customer_id, :shipment_confirmed, %{
        shipment_id: shipment_id,
        tracking_number: tracking_number,
        carrier: shipment.carrier
      })

      {:ok, :confirmed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def record_delivery_event(shipment_id, event_type, metadata) do
    with {:ok, shipment} <- Shipment.get(shipment_id) do
      event = %TrackingEvent{
        id: generate_event_id(),
        shipment_id: shipment_id,
        event_type: event_type,
        metadata: metadata,
        occurred_at: DateTime.utc_now()
      }

      {:ok, _} = TrackingEvent.insert(event)

      case event_type do
        :delivered ->
          {:ok, _} = Shipment.update(shipment_id, %{status: :delivered, delivered_at: DateTime.utc_now()})
          {:ok, order} = Order.get(shipment.order_id)
          {:ok, _} = Order.update(shipment.order_id, %{status: :delivered})
          {:ok, _} = Notification.send(order.customer_id, :order_delivered, shipment)

        :failed_delivery ->
          {:ok, _} = Shipment.update(shipment_id, %{status: :delivery_failed})

        :in_transit ->
          {:ok, _} = Shipment.update(shipment_id, %{status: :in_transit, last_location: metadata[:location]})

        _ ->
          :ok
      end

      {:ok, event}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_shipment(shipment_id, reason) do
    with {:ok, shipment} <- Shipment.get(shipment_id),
         :ok <- validate_cancellable(shipment),
         :ok <- Carrier.cancel_label(shipment.carrier, shipment.tracking_number) do

      {:ok, _} = Shipment.update(shipment_id, %{
        status: :cancelled,
        cancellation_reason: reason,
        cancelled_at: DateTime.utc_now()
      })

      {:ok, order} = Order.get(shipment.order_id)
      {:ok, _} = Order.update(shipment.order_id, %{status: :cancellation_requested})

      {:ok, :cancelled}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_carrier(order, warehouse) do
    total_weight = Enum.sum(Enum.map(order.line_items, & &1.weight_kg))

    cond do
      total_weight > @max_shipment_weight_kg -> {:error, :shipment_too_heavy}
      order.requires_signature -> {:ok, :ups}
      order.shipping_class == :express -> {:ok, :fedex}
      true -> {:ok, @default_carrier}
    end
  end

  defp validate_order_fulfillable(%{status: :confirmed}), do: :ok
  defp validate_order_fulfillable(%{status: :processing}), do: {:error, :already_processing}
  defp validate_order_fulfillable(_), do: {:error, :order_not_fulfillable}

  defp validate_shipment_splittable(%{status: :pending}), do: :ok
  defp validate_shipment_splittable(_), do: {:error, :shipment_cannot_be_split}

  defp validate_shipment_confirmable(%{status: :pending}), do: :ok
  defp validate_shipment_confirmable(_), do: {:error, :shipment_not_confirmable}

  defp validate_cancellable(%{status: status}) when status in [:pending, :confirmed], do: :ok
  defp validate_cancellable(_), do: {:error, :shipment_not_cancellable}

  defp generate_shipment_id do
    "shp_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp generate_event_id do
    "evt_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
```
