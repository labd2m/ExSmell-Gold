```elixir
defmodule Logistics.ShipmentDispatcher do
  @moduledoc """
  Coordinates the full dispatch pipeline for outbound shipments.
  """

  require Logger

  alias Logistics.{
    Order,
    Shipment,
    ShipmentLabel,
    InventoryReservation,
    WarehouseTask,
    Repo,
    CarrierGateway,
    Notifications
  }

  @carrier_priority [:fedex, :ups, :dhl, :usps]
  @max_weight_kg 70
  @oversize_surcharge_cents 2500

  def dispatch_shipment(order_id, dispatch_opts) do
    order = Repo.get!(Order, order_id) |> Repo.preload([:customer, :line_items])

    if order.status != :confirmed do
      Logger.warn("Cannot dispatch order #{order_id} in status=#{order.status}")
      {:error, :invalid_order_status}
    end

    # --- 1. Reserve inventory for each line item ---
    reservation_results =
      Enum.map(order.line_items, fn item ->
        available =
          Repo.one(
            from r in InventoryReservation,
              where: r.sku == ^item.sku and r.warehouse_id == ^dispatch_opts.warehouse_id,
              select: r.available_qty
          ) || 0

        if available < item.quantity do
          {:error, {:insufficient_stock, item.sku, available}}
        else
          {:ok,
           Repo.insert!(%InventoryReservation{
             sku: item.sku,
             warehouse_id: dispatch_opts.warehouse_id,
             order_id: order.id,
             quantity: item.quantity,
             reserved_at: DateTime.utc_now()
           })}
        end
      end)

    failed_reservations = Enum.filter(reservation_results, &match?({:error, _}, &1))

    unless Enum.empty?(failed_reservations) do
      Logger.error("Inventory reservation failed for order #{order_id}: #{inspect(failed_reservations)}")
      {:error, {:reservation_failed, failed_reservations}}
    end

    # --- 2. Compute shipment weight and dimensions ---
    total_weight_kg =
      Enum.reduce(order.line_items, 0.0, fn item, acc ->
        acc + item.unit_weight_kg * item.quantity
      end)

    is_oversize = total_weight_kg > @max_weight_kg

    package_dimensions = %{
      weight_kg: total_weight_kg,
      length_cm: dispatch_opts[:length_cm] || 40,
      width_cm: dispatch_opts[:width_cm] || 30,
      height_cm: dispatch_opts[:height_cm] || 20
    }

    # --- 3. Select carrier and fetch rates ---
    destination = order.customer.shipping_address

    carrier_quotes =
      @carrier_priority
      |> Enum.map(fn carrier ->
        case CarrierGateway.get_rate(carrier, destination, package_dimensions) do
          {:ok, rate} -> {carrier, rate}
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(carrier_quotes) do
      Logger.error("No carrier available for order #{order_id}")
      {:error, :no_carrier_available}
    end

    {selected_carrier, base_rate} = Enum.min_by(carrier_quotes, fn {_c, r} -> r.amount_cents end)

    shipping_cost =
      if is_oversize do
        base_rate.amount_cents + @oversize_surcharge_cents
      else
        base_rate.amount_cents
      end

    # --- 4. Generate shipping label ---
    {:ok, label} =
      CarrierGateway.create_label(selected_carrier, %{
        sender: dispatch_opts.warehouse_address,
        recipient: destination,
        package: package_dimensions,
        service: base_rate.service_code,
        reference: "ORD-#{order.id}"
      })

    {:ok, label_record} =
      %ShipmentLabel{}
      |> ShipmentLabel.changeset(%{
        carrier: selected_carrier,
        tracking_number: label.tracking_number,
        label_url: label.label_url,
        service_code: base_rate.service_code
      })
      |> Repo.insert()

    # --- 5. Persist shipment record ---
    {:ok, shipment} =
      %Shipment{}
      |> Shipment.changeset(%{
        order_id: order.id,
        warehouse_id: dispatch_opts.warehouse_id,
        carrier: selected_carrier,
        tracking_number: label.tracking_number,
        label_id: label_record.id,
        shipping_cost_cents: shipping_cost,
        is_oversize: is_oversize,
        estimated_delivery: base_rate.estimated_delivery,
        status: :label_created,
        dispatched_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Repo.update!(Order.changeset(order, %{status: :dispatched}))

    # --- 6. Create warehouse pick-and-pack task ---
    Repo.insert!(%WarehouseTask{
      shipment_id: shipment.id,
      warehouse_id: dispatch_opts.warehouse_id,
      task_type: :pick_and_pack,
      priority: if(order.customer.is_vip, do: :high, else: :normal),
      assigned_at: DateTime.utc_now()
    })

    # --- 7. Notify customer ---
    Notifications.send_shipment_confirmation(order.customer, %{
      order_id: order.id,
      tracking_number: label.tracking_number,
      carrier: selected_carrier,
      estimated_delivery: base_rate.estimated_delivery
    })

    Logger.info("Shipment dispatched order_id=#{order.id} tracking=#{label.tracking_number}")
    {:ok, shipment}
  end

  def track_shipment(tracking_number) do
    case Repo.get_by(Shipment, tracking_number: tracking_number) do
      nil -> {:error, :not_found}
      shipment -> CarrierGateway.get_status(shipment.carrier, tracking_number)
    end
  end
end
```
