# Example Bad 10 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_eta_days/2`, `assign_warehouse/1`, `get_carrier/1`, and `generate_label_format/1` inside `Orders.FulfillmentManager`
- **Affected Functions**: `calculate_eta_days/2`, `assign_warehouse/1`, `get_carrier/1`, `generate_label_format/1`
- **Explanation**: The fulfillment method logic (`:pickup`, `:standard_shipping`, `:express_shipping`) is spread across four separate functions. Adding a new fulfillment method (e.g., `:locker_delivery`) forces four independent, scattered edits — a clear case of Shotgun Surgery.

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

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new fulfillment method (e.g., :locker_delivery)
  # requires a new clause here AND in assign_warehouse/1, get_carrier/1,
  # and generate_label_format/1 — four scattered changes for one new method.
  def calculate_eta_days(_zip, :pickup),           do: 0
  def calculate_eta_days(_zip, :standard_shipping), do: 5
  def calculate_eta_days(_zip, :express_shipping),  do: 1
  def calculate_eta_days(_zip, _method),            do: 7
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new fulfillment method also requires a new
  # warehouse assignment clause here, independent of calculate_eta_days/2.
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
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new fulfillment method also needs a carrier
  # clause here, independent of the previous two locations.
  def get_carrier(:pickup),           do: :in_store
  def get_carrier(:standard_shipping), do: :ups_ground
  def get_carrier(:express_shipping),  do: :fedex_overnight
  def get_carrier(_),                  do: :generic_carrier
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new fulfillment method also requires a new
  # label format clause here, completing the four-location change.
  def generate_label_format(:pickup),            do: :qr_code
  def generate_label_format(:standard_shipping), do: :thermal_4x6
  def generate_label_format(:express_shipping),  do: :thermal_4x6_priority
  def generate_label_format(_),                  do: :standard_label
  # VALIDATION: SMELL END [location 4 of 4]

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
