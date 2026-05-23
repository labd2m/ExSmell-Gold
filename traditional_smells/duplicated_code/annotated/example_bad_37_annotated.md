# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Logistics.ShipmentRouter.cheapest_carrier/1` and `Logistics.ShipmentRouter.fastest_carrier/1` |
| **Affected functions** | `cheapest_carrier/1`, `fastest_carrier/1` |
| **Short explanation** | Both functions duplicate the same carrier-eligibility filtering logic (weight limit, restricted destination countries, dangerous-goods flag). If a new restriction is added—e.g., a carrier drops a country—both branches must be updated, increasing the risk of an oversight. |

```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Selects the optimal carrier for a shipment based on cost or transit time.
  """

  alias Logistics.{Carrier, Shipment, RateCard, Quote}

  @max_standard_weight_kg 70.0
  @restricted_countries   ~w[KP IR SY CU)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the carrier with the lowest landed cost for the given shipment.
  """
  def cheapest_carrier(%Shipment{} = shipment) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the carrier eligibility filter
    # (weight, restricted countries, dangerous goods) is copy-pasted
    # verbatim in fastest_carrier/1. A new restriction must be added in
    # both functions.
    eligible_carriers =
      Carrier.all_active()
      |> Enum.filter(fn carrier ->
        shipment.weight_kg <= @max_standard_weight_kg or
          :heavy_freight in carrier.capabilities
      end)
      |> Enum.filter(fn carrier ->
        shipment.destination_country not in @restricted_countries or
          :sanctioned_goods in carrier.licences
      end)
      |> Enum.filter(fn carrier ->
        not shipment.dangerous_goods? or :dangerous_goods in carrier.licences
      end)
    # VALIDATION: SMELL END

    if Enum.empty?(eligible_carriers) do
      {:error, :no_eligible_carrier}
    else
      quotes =
        eligible_carriers
        |> Enum.map(&{&1, RateCard.landed_cost(&1, shipment)})
        |> Enum.sort_by(fn {_carrier, cost} -> cost end)

      {best_carrier, best_cost} = hd(quotes)

      {:ok,
       %Quote{
         carrier:       best_carrier,
         shipment_id:   shipment.id,
         estimated_cost: best_cost,
         selected_by:   :lowest_cost,
         generated_at:  DateTime.utc_now()
       }}
    end
  end

  @doc """
  Returns the carrier with the shortest estimated transit time.
  """
  def fastest_carrier(%Shipment{} = shipment) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the identical carrier eligibility
    # filter already appears in cheapest_carrier/1. Both blocks must be kept
    # in sync manually.
    eligible_carriers =
      Carrier.all_active()
      |> Enum.filter(fn carrier ->
        shipment.weight_kg <= @max_standard_weight_kg or
          :heavy_freight in carrier.capabilities
      end)
      |> Enum.filter(fn carrier ->
        shipment.destination_country not in @restricted_countries or
          :sanctioned_goods in carrier.licences
      end)
      |> Enum.filter(fn carrier ->
        not shipment.dangerous_goods? or :dangerous_goods in carrier.licences
      end)
    # VALIDATION: SMELL END

    if Enum.empty?(eligible_carriers) do
      {:error, :no_eligible_carrier}
    else
      quotes =
        eligible_carriers
        |> Enum.map(&{&1, RateCard.transit_days(&1, shipment)})
        |> Enum.sort_by(fn {_carrier, days} -> days end)

      {best_carrier, transit_days} = hd(quotes)

      {:ok,
       %Quote{
         carrier:        best_carrier,
         shipment_id:    shipment.id,
         transit_days:   transit_days,
         selected_by:    :fastest_transit,
         generated_at:   DateTime.utc_now()
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_shipment(%Shipment{weight_kg: w}) when w <= 0,
    do: {:error, :invalid_weight}
  defp validate_shipment(%Shipment{dimensions: nil}),
    do: {:error, :missing_dimensions}
  defp validate_shipment(_shipment), do: :ok
end
```
