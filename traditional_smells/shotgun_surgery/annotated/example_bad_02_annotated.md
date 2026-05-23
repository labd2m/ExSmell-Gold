# Example Bad 02 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_rate/2`, `estimate_delivery_days/2`, `assign_carrier/1`, and `generate_tracking_prefix/1` inside `Logistics.ShipmentProcessor`
- **Affected Functions**: `calculate_rate/2`, `estimate_delivery_days/2`, `assign_carrier/1`, `generate_tracking_prefix/1`
- **Explanation**: The shipment priority level logic (`:standard`, `:express`, `:overnight`) is fragmented across four functions. Introducing a new priority level (e.g., `:same_day`) requires four separate, independent edits in different parts of the same module — a clear sign of Shotgun Surgery.

```elixir
defmodule Logistics.ShipmentProcessor do
  @moduledoc """
  Processes outbound shipments including rate calculation, delivery estimation,
  carrier assignment, and tracking number generation for different priority levels.
  """

  alias Logistics.{Shipment, CarrierGateway, TrackingRegistry, RateAudit}

  @base_rate_per_kg 2.50

  def process_shipment(%Shipment{} = shipment) do
    with {:ok, rated}    <- rate_shipment(shipment),
         {:ok, assigned} <- assign_and_track(rated),
         {:ok, _}        <- RateAudit.record(assigned) do
      {:ok, assigned}
    end
  end

  defp rate_shipment(%Shipment{} = shipment) do
    rate         = calculate_rate(shipment.weight_kg, shipment.priority)
    delivery_eta = estimate_delivery_days(shipment.origin_zone, shipment.priority)

    {:ok, %{shipment | quoted_rate: rate, estimated_delivery_days: delivery_eta}}
  end

  defp assign_and_track(%Shipment{} = shipment) do
    carrier  = assign_carrier(shipment.priority)
    prefix   = generate_tracking_prefix(shipment.priority)
    tracking = "#{prefix}-#{TrackingRegistry.next_sequence()}"

    case CarrierGateway.book(carrier, shipment, tracking) do
      {:ok, confirmation} ->
        {:ok, %{shipment | carrier: carrier, tracking_number: tracking, carrier_ref: confirmation}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new priority level (e.g., :same_day)
  # requires a new clause here AND in estimate_delivery_days/2, assign_carrier/1,
  # and generate_tracking_prefix/1 — four scattered changes for one new feature.
  def calculate_rate(weight_kg, :standard) do
    Float.round(@base_rate_per_kg * weight_kg * 1.0, 2)
  end

  def calculate_rate(weight_kg, :express) do
    Float.round(@base_rate_per_kg * weight_kg * 1.8, 2)
  end

  def calculate_rate(weight_kg, :overnight) do
    Float.round(@base_rate_per_kg * weight_kg * 3.2, 2)
  end

  def calculate_rate(weight_kg, _priority) do
    Float.round(@base_rate_per_kg * weight_kg, 2)
  end
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new priority also requires a new clause here,
  # independently from the changes needed in calculate_rate/2.
  def estimate_delivery_days(_origin_zone, :standard),  do: 5
  def estimate_delivery_days(_origin_zone, :express),   do: 2
  def estimate_delivery_days(_origin_zone, :overnight), do: 1
  def estimate_delivery_days(_origin_zone, _priority),  do: 7
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new priority requires yet another change here,
  # independent of the two previous locations.
  defp assign_carrier(:standard),  do: :fedex_ground
  defp assign_carrier(:express),   do: :fedex_express
  defp assign_carrier(:overnight), do: :fedex_priority_overnight
  defp assign_carrier(_),          do: :fedex_ground
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new priority also needs a new prefix clause here,
  # completing the four-point modification required for every new priority level.
  defp generate_tracking_prefix(:standard),  do: "STD"
  defp generate_tracking_prefix(:express),   do: "EXP"
  defp generate_tracking_prefix(:overnight), do: "OVN"
  defp generate_tracking_prefix(_),          do: "GEN"
  # VALIDATION: SMELL END [location 4 of 4]

  def validate_shipment(%Shipment{weight_kg: w}) when w <= 0 do
    {:error, :invalid_weight}
  end

  def validate_shipment(%Shipment{destination: nil}) do
    {:error, :missing_destination}
  end

  def validate_shipment(%Shipment{} = shipment) do
    if shipment.origin_zone && shipment.priority do
      {:ok, shipment}
    else
      {:error, :incomplete_shipment_data}
    end
  end

  def list_available_priorities do
    [:standard, :express, :overnight]
  end

  def build_shipment(params) do
    %Shipment{
      origin_zone:  Map.fetch!(params, :origin_zone),
      destination:  Map.fetch!(params, :destination),
      weight_kg:    Map.fetch!(params, :weight_kg),
      priority:     Map.get(params, :priority, :standard),
      contents:     Map.get(params, :contents, []),
      reference:    Map.get(params, :reference)
    }
  end
end
```
