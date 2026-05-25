## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** Module `Logistics.ShipmentCostAdjuster` (defined at the bottom of the file)
- **Affected function(s):** All functions within `Logistics.ShipmentCostAdjuster` — `adjust/2`
- **Explanation:** `ShipmentCostAdjuster` was written speculatively to provide pluggable, carrier-specific cost-adjustment strategies (standard, preferred partner, bulk agreement, spot rate). In practice, this module is never aliased, imported, or called from any other module in the codebase. All cost computation lives entirely inside `ShipmentDispatcher.calculate_cost/2`. The module is dead code that enlarges the maintenance surface without providing any benefit.

---

```elixir
defmodule Logistics.ShipmentDispatcher do
  @moduledoc """
  Coordinates dispatch decisions, carrier assignment, and cost computation
  for outbound shipments across all distribution centres.
  """

  alias Logistics.{Shipment, Carrier, Route, DeliveryWindow}

  @base_rate_per_kg       2.50
  @fuel_surcharge_rate    0.12
  @residential_surcharge  4.75
  @oversized_girth_limit  165
  @express_surcharge_rate 0.65

  def dispatch(%Shipment{} = shipment) do
    with {:ok, route}   <- select_route(shipment),
         {:ok, carrier} <- assign_carrier(shipment, route),
         {:ok, cost}    <- calculate_cost(shipment, route),
         {:ok, window}  <- DeliveryWindow.estimate(shipment, route, carrier) do
      {:ok,
       %{
         shipment_id:        shipment.id,
         carrier_name:       carrier.name,
         route_code:         route.code,
         estimated_cost_usd: cost,
         delivery_window:    window
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def calculate_cost(%Shipment{} = shipment, route) do
    base            = shipment.weight_kg * @base_rate_per_kg
    fuel            = base * @fuel_surcharge_rate
    residential     = if shipment.residential_delivery?, do: @residential_surcharge, else: 0.0
    oversized       = if oversized?(shipment), do: 28.00, else: 0.0
    distance_factor = route.distance_km / 1_000 * 1.5
    express         = if shipment.express?, do: base * @express_surcharge_rate, else: 0.0

    total = base + fuel + residential + oversized + distance_factor + express
    {:ok, Float.round(total, 2)}
  end

  def oversized?(%Shipment{dimensions: %{length: l, width: w, height: h}}) do
    l + 2 * (w + h) > @oversized_girth_limit
  end

  def list_pending_for_carrier(carrier_id) do
    Shipment.query()
    |> Shipment.where_status(:pending)
    |> Shipment.where_carrier(carrier_id)
    |> Shipment.all()
  end

  def cancel(%Shipment{status: :dispatched}), do: {:error, :already_dispatched}
  def cancel(%Shipment{id: id}), do: Shipment.update(id, %{status: :cancelled})

  defp select_route(%Shipment{origin: origin, destination: destination}) do
    case Route.find(origin, destination) do
      nil   -> {:error, :no_route_available}
      route -> {:ok, route}
    end
  end

  defp assign_carrier(%Shipment{weight_kg: weight, express?: express?}, route) do
    candidates =
      route
      |> Carrier.available_for_route()
      |> Enum.filter(&(&1.max_weight_kg >= weight))
      |> then(fn cs ->
        if express?, do: Enum.filter(cs, & &1.express_capable?), else: cs
      end)

    case Enum.min_by(candidates, & &1.base_rate, fn -> nil end) do
      nil     -> {:error, :no_carrier_available}
      carrier -> {:ok, carrier}
    end
  end
end

# VALIDATION: SMELL START - Speculative Generality
# VALIDATION: This is a smell because `Logistics.ShipmentCostAdjuster` was written
# speculatively to support pluggable, per-carrier cost adjustment strategies.
# The module provides four named strategies (standard, preferred_partner,
# bulk_agreement, spot_rate), but it is never aliased, imported, or invoked from
# any module in the codebase. All cost logic lives entirely inside
# `ShipmentDispatcher.calculate_cost/2`. This dead module exists solely due to
# an assumption about future requirements that never materialised, adding
# unnecessary complexity and maintenance burden.
defmodule Logistics.ShipmentCostAdjuster do
  @moduledoc """
  Pluggable cost-adjustment strategies for carrier-specific pricing agreements.
  Designed to be invoked by ShipmentDispatcher to honour contract-level discounts.
  """

  def adjust(cost, :standard),          do: cost
  def adjust(cost, :preferred_partner), do: Float.round(cost * 0.88, 2)
  def adjust(cost, :bulk_agreement),    do: Float.round(cost * 0.82, 2)
  def adjust(cost, :spot_rate),         do: Float.round(cost * 1.10, 2)
  def adjust(cost, _unknown),           do: cost
end
# VALIDATION: SMELL END
```
