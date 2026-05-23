```elixir
defmodule Orders.FulfillmentManager do
  @moduledoc """
  Manages order fulfillment workflows including ETA estimation,
  warehouse assignment, carrier selection, and shipping label generation
  for different fulfillment methods in the e-commerce platform.
  """

  alias Orders.{Order, WarehouseRegistry, CarrierClient, LabelService, CustomerNotifier}

  def fulfill_order(%Order{} = order) do
    with {:ok, order}   <- assign_fulfillment_resources(order),
         {:ok, label}   <- generate_shipping_label(order),
         {:ok, order}   <- update_order_status(order, label),
         :ok            <- CustomerNotifier.send_confirmation(order) do
      {:ok, order}
    end
  end

  defp assign_fulfillment_resources(%Order{} = order) do
    warehouse = assign_warehouse(order.fulfillment_method)
    carrier   = get_carrier(order.fulfillment_method)
    eta_days  = calculate_eta_days(order.destination_zip, order.fulfillment_method)

    {:ok, %{order |
      warehouse_id: warehouse.id,
      carrier:      carrier,
      eta:          Date.add(Date.utc_today(), eta_days)
    }}
  end

  defp generate_shipping_label(%Order{} = order) do
    label_format = generate_label_format(order.fulfillment_method)
    LabelService.generate(order, format: label_format)
  end

  defp update_order_status(order, label) do
    updated = %{order |
      tracking_number: label.tracking_number,
      status:          :awaiting_pickup,
      label_url:       label.url,
      fulfilled_at:    DateTime.utc_now()
    }

    Orders.Repo.update(updated)
  end

  def calculate_eta_days(_zip, :pickup),           do: 0
  def calculate_eta_days(_zip, :standard_shipping), do: 5
  def calculate_eta_days(_zip, :express_shipping),  do: 1
  def calculate_eta_days(_zip, _method),            do: 7

  def assign_warehouse(:pickup) do
    WarehouseRegistry.get_by_type(:retail_store)
  end

  def assign_warehouse(:standard_shipping) do
    WarehouseRegistry.get_by_type(:distribution_center)
  end

  def assign_warehouse(:express_shipping) do
    WarehouseRegistry.get_by_type(:express_hub)
  end

  def assign_warehouse(_method) do
    WarehouseRegistry.get_default()
  end

  def get_carrier(:pickup),           do: :in_store
  def get_carrier(:standard_shipping), do: :ups_ground
  def get_carrier(:express_shipping),  do: :fedex_overnight
  def get_carrier(_),                  do: :generic_carrier

  def generate_label_format(:pickup),            do: :qr_code
  def generate_label_format(:standard_shipping), do: :thermal_4x6
  def generate_label_format(:express_shipping),  do: :thermal_4x6_priority
  def generate_label_format(_),                  do: :standard_label

  def cancel_fulfillment(%Order{status: :awaiting_pickup} = order, reason) do
    with :ok <- CarrierClient.cancel_shipment(order.tracking_number),
         :ok <- WarehouseRegistry.release_slot(order.warehouse_id, order.id) do
      updated = %{order | status: :cancelled, cancellation_reason: reason}
      Orders.Repo.update(updated)
    end
  end

  def cancel_fulfillment(%Order{status: status}, _reason) do
    {:error, {:cannot_cancel, status}}
  end

  def get_tracking_info(%Order{carrier: :in_store, tracking_number: tracking}) do
    {:ok, %{status: :ready_for_pickup, message: "Your order is ready. Reference: #{tracking}"}}
  end

  def get_tracking_info(%Order{tracking_number: tracking, carrier: carrier}) do
    CarrierClient.track(carrier, tracking)
  end

  def list_fulfillment_methods do
    [:pickup, :standard_shipping, :express_shipping]
  end
end
```
