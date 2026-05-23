```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Selects the optimal carrier for a shipment based on cost or transit time.
  """

  alias Logistics.{Carrier, Shipment, RateCard, Quote}

  @max_standard_weight_kg 70.0
  @restricted_countries   ~w[KP IR SY CU)


  @doc """
  Returns the carrier with the lowest landed cost for the given shipment.
  """
  def cheapest_carrier(%Shipment{} = shipment) do
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


  defp validate_shipment(%Shipment{weight_kg: w}) when w <= 0,
    do: {:error, :invalid_weight}
  defp validate_shipment(%Shipment{dimensions: nil}),
    do: {:error, :missing_dimensions}
  defp validate_shipment(_shipment), do: :ok
end
```
