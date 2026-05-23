# Annotated Example — Feature Envy

| Field                  | Value                                                                                     |
|------------------------|-------------------------------------------------------------------------------------------|
| **Smell name**         | Feature Envy                                                                              |
| **Smell location**     | `Logistics.ShipmentService.calculate_package_charges/1`                                   |
| **Affected function**  | `calculate_package_charges/1`                                                             |
| **Explanation**        | The function operates almost exclusively on data from the `Package` module—calling `Package.dimensions/1`, `Package.weight_kg/1`, `Package.declared_value/1`, `Package.fragile?/1`, `Package.requires_signature?/1`, `Package.insurance_tier/1`—and reading `package.origin_zone`, `package.dest_zone`. `ShipmentService` contributes only arithmetic on top of `Package` data; the function would be far more cohesive inside `Package`. |

```elixir
defmodule Logistics.ShipmentService do
  @moduledoc """
  Handles shipment creation, tracking, and carrier coordination.
  """

  alias Logistics.{Package, Carrier, TrackingEvent, Zone}
  require Logger

  @base_handling_fee 2.50
  @fuel_surcharge_rate 0.08

  def create_shipment(attrs) do
    with {:ok, pkg} <- Package.validate(attrs[:package]),
         {:ok, carrier} <- Carrier.assign(attrs[:carrier_code]),
         {:ok, tracking} <- generate_tracking_number(carrier) do
      {:ok, %{package: pkg, carrier: carrier, tracking: tracking, status: :created}}
    end
  end

  def update_shipment_status(shipment_id, status) do
    Logger.info("Updating shipment #{shipment_id} to status #{status}")
    {:ok, %{shipment_id: shipment_id, status: status, updated_at: DateTime.utc_now()}}
  end

  def record_event(shipment_id, event_type, location) do
    event = TrackingEvent.build(shipment_id, event_type, location, DateTime.utc_now())
    TrackingEvent.persist(event)
  end

  def mark_delivered(shipment_id) do
    Logger.info("Marking shipment #{shipment_id} as delivered")
    {:ok, %{shipment_id: shipment_id, status: :delivered, delivered_at: DateTime.utc_now()}}
  end

  def cancel_shipment(shipment_id, reason) do
    Logger.warn("Cancelling shipment #{shipment_id}: #{reason}")
    {:ok, %{shipment_id: shipment_id, status: :cancelled, reason: reason}}
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because calculate_package_charges/1 operates almost exclusively
  # VALIDATION: on data from the Package module—calling Package.dimensions/1,
  # VALIDATION: Package.weight_kg/1, Package.declared_value/1, Package.fragile?/1,
  # VALIDATION: Package.requires_signature?/1, Package.insurance_tier/1—and reading
  # VALIDATION: package.origin_zone, package.dest_zone. ShipmentService contributes only
  # VALIDATION: minor arithmetic (dimensional weight formula, surcharge percentages);
  # VALIDATION: all meaningful data and behaviour originate from Package.
  def calculate_package_charges(package_id) do
    package = Package.get!(package_id)

    dimensions = Package.dimensions(package)
    volume_cm3 = dimensions.length * dimensions.width * dimensions.height
    dimensional_weight = volume_cm3 / 5000.0

    actual_weight = Package.weight_kg(package)
    billable_weight = max(actual_weight, dimensional_weight)

    declared_value = Package.declared_value(package)
    insurance_tier = Package.insurance_tier(package)

    base_rate = Zone.rate_between(package.origin_zone, package.dest_zone)
    weight_charge = billable_weight * base_rate

    fragile_surcharge = if Package.fragile?(package), do: weight_charge * 0.15, else: 0.0
    signature_fee = if Package.requires_signature?(package), do: 3.50, else: 0.0

    insurance_fee =
      case insurance_tier do
        :basic -> declared_value * 0.01
        :extended -> declared_value * 0.025
        :none -> 0.0
      end

    fuel_surcharge = weight_charge * @fuel_surcharge_rate

    total =
      weight_charge +
        fragile_surcharge +
        signature_fee +
        insurance_fee +
        fuel_surcharge +
        @base_handling_fee

    %{
      billable_weight_kg: Float.round(billable_weight, 3),
      base_rate_per_kg: base_rate,
      weight_charge: Float.round(weight_charge, 2),
      fragile_surcharge: Float.round(fragile_surcharge, 2),
      signature_fee: signature_fee,
      insurance_fee: Float.round(insurance_fee, 2),
      fuel_surcharge: Float.round(fuel_surcharge, 2),
      handling_fee: @base_handling_fee,
      total: Float.round(total, 2)
    }
  end
  # VALIDATION: SMELL END

  def estimate_delivery_date(shipment_id) do
    {:ok, %{shipment_id: shipment_id, estimated_delivery: Date.add(Date.utc_today(), 3)}}
  end

  def list_events(shipment_id) do
    TrackingEvent.list_for_shipment(shipment_id)
  end

  defp generate_tracking_number(carrier) do
    number = "#{carrier.code}-#{:rand.uniform(999_999_999)}"
    {:ok, number}
  end
end
```
