```elixir
defmodule Logistics.Routes.CarrierSelector do
  @moduledoc """
  Selects the optimal carrier for a shipment based on service level,
  price, and dimensional weight constraints.
  Carrier eligibility is evaluated against shipment properties;
  the best candidate is chosen by a configurable ranking strategy.
  """

  @type dimensions :: %{length_cm: float(), width_cm: float(), height_cm: float()}
  @type shipment :: %{
          origin_country: String.t(),
          destination_country: String.t(),
          weight_kg: float(),
          dimensions: dimensions(),
          service_level: :express | :standard | :economy,
          declared_value_cents: non_neg_integer()
        }

  @type carrier :: %{
          id: String.t(),
          name: String.t(),
          supported_service_levels: [:express | :standard | :economy],
          max_weight_kg: float(),
          max_dimensional_weight_kg: float(),
          supported_routes: [{String.t(), String.t()}],
          base_rate_cents: pos_integer(),
          rate_per_kg_cents: pos_integer()
        }

  @type quote :: %{
          carrier_id: String.t(),
          carrier_name: String.t(),
          estimated_cost_cents: non_neg_integer(),
          service_level: atom()
        }

  @dimensional_factor 5000.0

  @doc """
  Returns ranked carrier quotes for `shipment` from the `carriers` list.
  Quotes are sorted by estimated cost ascending.
  Returns `{:ok, [quote()]}` or `{:error, reason}` on invalid input.
  """
  @spec rank(shipment(), [carrier()]) :: {:ok, [quote()]} | {:error, String.t()}
  def rank(shipment, carriers) when is_map(shipment) and is_list(carriers) do
    with :ok <- validate_shipment(shipment) do
      dim_weight = dimensional_weight(shipment.dimensions)
      chargeable_weight = max(shipment.weight_kg, dim_weight)

      quotes =
        carriers
        |> Enum.filter(fn c -> eligible?(c, shipment, chargeable_weight) end)
        |> Enum.map(fn c -> build_quote(c, chargeable_weight) end)
        |> Enum.sort_by(fn q -> q.estimated_cost_cents end)

      {:ok, quotes}
    end
  end

  @doc """
  Returns the single lowest-cost eligible carrier quote for `shipment`.
  Returns `{:error, :no_eligible_carriers}` when no carrier qualifies.
  """
  @spec select_cheapest(shipment(), [carrier()]) ::
          {:ok, quote()} | {:error, :no_eligible_carriers | String.t()}
  def select_cheapest(shipment, carriers) do
    case rank(shipment, carriers) do
      {:ok, [best | _]} -> {:ok, best}
      {:ok, []} -> {:error, :no_eligible_carriers}
      {:error, _} = err -> err
    end
  end

  defp eligible?(carrier, shipment, chargeable_weight) do
    route = {shipment.origin_country, shipment.destination_country}

    shipment.service_level in carrier.supported_service_levels and
      route in carrier.supported_routes and
      chargeable_weight <= carrier.max_weight_kg and
      chargeable_weight <= carrier.max_dimensional_weight_kg
  end

  defp build_quote(carrier, chargeable_weight) do
    cost = carrier.base_rate_cents + round(chargeable_weight * carrier.rate_per_kg_cents)

    %{
      carrier_id: carrier.id,
      carrier_name: carrier.name,
      estimated_cost_cents: cost,
      service_level: carrier.supported_service_levels |> List.first()
    }
  end

  defp dimensional_weight(%{length_cm: l, width_cm: w, height_cm: h}) do
    l * w * h / @dimensional_factor
  end

  defp validate_shipment(%{
         origin_country: oc,
         destination_country: dc,
         weight_kg: wt,
         dimensions: %{length_cm: l, width_cm: w, height_cm: h},
         service_level: sl,
         declared_value_cents: dv
       })
       when is_binary(oc) and byte_size(oc) == 2 and
              is_binary(dc) and byte_size(dc) == 2 and
              is_float(wt) and wt > 0.0 and
              is_float(l) and l > 0.0 and
              is_float(w) and w > 0.0 and
              is_float(h) and h > 0.0 and
              sl in [:express, :standard, :economy] and
              is_integer(dv) and dv >= 0,
       do: :ok

  defp validate_shipment(_shipment) do
    {:error,
     "shipment must have valid origin/destination ISO codes, positive weight and dimensions, a service level, and declared value"}
  end
end
```
