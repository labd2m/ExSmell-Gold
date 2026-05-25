# Example Bad 02 — Annotated

## Metadata

- **Smell Name**: Speculative Generality
- **Expected Smell Location**: `Logistics.ShipmentCostCalculator.calculate_cost/1`
- **Affected Function(s)**: `calculate_cost/1`
- **Explanation**: The function pattern-matches on the `carrier` field of `%Shipment{}`
  to allow carrier-specific cost computations in the future. However, every branch in
  the `case` expression — `:fedex`, `:ups`, `:dhl`, and the catch-all — executes the
  exact same formula. The branching structure was introduced speculatively and never
  filled with differentiated logic, making the entire `case` redundant.

## Code

```elixir
defmodule Logistics.ShipmentCostCalculator do
  @moduledoc """
  Calculates shipping costs for outbound shipments based on weight,
  destination zone, and carrier rate cards. Used by the dispatch pipeline
  before committing a shipment to a carrier.
  """

  alias Logistics.{Shipment, Zone, RateCard, Repo}

  @base_handling_fee   2.50
  @fuel_surcharge_rate 0.08
  @residential_fee     3.00
  @oversized_threshold 31.5

  def calculate_cost(%Shipment{carrier: carrier} = shipment) do
    zone = Zone.resolve(shipment.origin_zip, shipment.destination_zip)
    rate = RateCard.lookup!(zone, shipment.weight_kg)

    # VALIDATION: SMELL START - Speculative Generality
    # VALIDATION: This is a smell because `carrier` is extracted via pattern
    # matching to allow different cost formulas per carrier. Every branch
    # executes the identical calculation, however, so the branching is purely
    # speculative—no carrier-specific logic was ever implemented.
    base_cost =
      case carrier do
        :fedex -> rate * shipment.weight_kg + @base_handling_fee
        :ups   -> rate * shipment.weight_kg + @base_handling_fee
        :dhl   -> rate * shipment.weight_kg + @base_handling_fee
        _      -> rate * shipment.weight_kg + @base_handling_fee
      end
    # VALIDATION: SMELL END

    surcharges = compute_surcharges(shipment)
    total      = Float.round(base_cost + surcharges, 2)

    {:ok, %{base_cost: Float.round(base_cost, 2), surcharges: surcharges, total: total}}
  end

  def calculate_cost_batch(shipments) when is_list(shipments) do
    Enum.map(shipments, fn shipment ->
      case calculate_cost(shipment) do
        {:ok, result} ->
          Map.put(result, :shipment_id, shipment.id)

        {:error, reason} ->
          %{shipment_id: shipment.id, error: reason}
      end
    end)
  end

  def cheapest_option(origin_zip, destination_zip, weight_kg) do
    carriers = [:fedex, :ups, :dhl]

    results =
      Enum.map(carriers, fn carrier ->
        probe = %Shipment{
          carrier:         carrier,
          origin_zip:      origin_zip,
          destination_zip: destination_zip,
          weight_kg:       weight_kg,
          residential:     false,
          oversized:       weight_kg > @oversized_threshold
        }

        case calculate_cost(probe) do
          {:ok, result} -> {carrier, result.total}
          _             -> {carrier, :unavailable}
        end
      end)

    results
    |> Enum.reject(fn {_, v} -> v == :unavailable end)
    |> Enum.min_by(fn {_, cost} -> cost end)
  end

  def persist_estimate(shipment_id, cost_breakdown) do
    shipment = Repo.get!(Shipment, shipment_id)

    shipment
    |> Shipment.changeset(%{
      estimated_cost:      cost_breakdown.total,
      cost_calculated_at:  DateTime.utc_now()
    })
    |> Repo.update()
  end

  def recalculate_all_pending do
    Shipment
    |> Repo.all()
    |> Enum.filter(&(&1.status == :pending_cost))
    |> Enum.each(fn shipment ->
      case calculate_cost(shipment) do
        {:ok, breakdown} -> persist_estimate(shipment.id, breakdown)
        {:error, _}      -> :skip
      end
    end)
  end

  # --- Private ---

  defp compute_surcharges(%Shipment{} = shipment) do
    fuel      = Float.round(shipment.weight_kg * @fuel_surcharge_rate, 2)
    res_fee   = if shipment.residential, do: @residential_fee, else: 0.0
    oversize  = if shipment.oversized, do: 25.0, else: 0.0
    Float.round(fuel + res_fee + oversize, 2)
  end
end
```
