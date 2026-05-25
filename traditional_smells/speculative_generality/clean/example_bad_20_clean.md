```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Computes optimal carrier routes based on delivery zone constraints.

  Intended to be used by CarrierSelector to pre-filter viable carriers
  before scoring them against SLA requirements.
  """

  @zone_carrier_map %{
    "northeast" => [:fedex, :ups, :usps],
    "southeast" => [:fedex, :dhl, :usps],
    "midwest" => [:ups, :ontrac, :usps],
    "west" => [:fedex, :ontrac, :lasership],
    "international" => [:dhl, :fedex]
  }

  @spec viable_carriers_for_zone(String.t()) :: {:ok, [atom()]} | {:error, :unknown_zone}
  def viable_carriers_for_zone(zone) do
    case Map.fetch(@zone_carrier_map, zone) do
      {:ok, carriers} -> {:ok, carriers}
      :error -> {:error, :unknown_zone}
    end
  end

  @spec filter_by_weight_class(float(), [atom()]) :: [atom()]
  def filter_by_weight_class(weight_kg, carriers) when weight_kg > 30.0 do
    Enum.reject(carriers, &(&1 == :lasership))
  end

  def filter_by_weight_class(_weight_kg, carriers), do: carriers

  @spec rank_by_cost(Shipment.t(), [atom()]) :: [{atom(), float()}]
  def rank_by_cost(%{declared_value: value, weight_kg: weight}, carriers) do
    carriers
    |> Enum.map(fn carrier -> {carrier, estimate_cost(carrier, weight, value)} end)
    |> Enum.sort_by(fn {_carrier, cost} -> cost end)
  end

  defp estimate_cost(:fedex, weight, _value), do: 4.50 + weight * 0.80
  defp estimate_cost(:ups, weight, _value), do: 4.20 + weight * 0.85
  defp estimate_cost(:dhl, weight, value), do: 5.00 + weight * 0.90 + value * 0.001
  defp estimate_cost(:usps, weight, _value), do: 3.80 + weight * 0.70
  defp estimate_cost(:ontrac, weight, _value), do: 3.50 + weight * 0.75
  defp estimate_cost(:lasership, weight, _value), do: 3.20 + weight * 0.65
  defp estimate_cost(_unknown, weight, _value), do: 99.99 + weight * 1.00
end

defmodule Logistics.CarrierSelector do
  @moduledoc """
  Selects the best carrier for a shipment based on SLA, cost, and availability.
  """

  alias Logistics.Shipment

  @sla_priority_carriers %{
    :next_day => [:fedex, :ups],
    :two_day => [:fedex, :ups, :dhl],
    :ground => [:ups, :usps, :ontrac, :lasership]
  }

  @spec select(Shipment.t()) :: {:ok, atom()} | {:error, :no_carrier_available}
  def select(%Shipment{sla_tier: sla_tier, destination_zip: zip} = shipment) do
    with {:ok, sla_carriers} <- fetch_sla_carriers(sla_tier),
         {:ok, available} <- check_carrier_availability(sla_carriers, zip) do
      carrier = pick_cheapest(available, shipment)
      {:ok, carrier}
    end
  end

  defp fetch_sla_carriers(sla_tier) do
    case Map.fetch(@sla_priority_carriers, sla_tier) do
      {:ok, carriers} -> {:ok, carriers}
      :error -> {:error, :no_carrier_available}
    end
  end

  defp check_carrier_availability(carriers, _zip) do
    available = Enum.filter(carriers, &carrier_online?/1)

    case available do
      [] -> {:error, :no_carrier_available}
      list -> {:ok, list}
    end
  end

  defp pick_cheapest(carriers, %Shipment{weight_kg: weight}) do
    Enum.min_by(carriers, fn carrier ->
      base_rate(carrier) + weight * per_kg_rate(carrier)
    end)
  end

  defp carrier_online?(:fedex), do: true
  defp carrier_online?(:ups), do: true
  defp carrier_online?(:dhl), do: true
  defp carrier_online?(:usps), do: true
  defp carrier_online?(:ontrac), do: false
  defp carrier_online?(:lasership), do: true
  defp carrier_online?(_), do: false

  defp base_rate(:fedex), do: 4.50
  defp base_rate(:ups), do: 4.20
  defp base_rate(:dhl), do: 5.00
  defp base_rate(:usps), do: 3.80
  defp base_rate(:lasership), do: 3.20
  defp base_rate(_), do: 99.99

  defp per_kg_rate(:fedex), do: 0.80
  defp per_kg_rate(:ups), do: 0.85
  defp per_kg_rate(:dhl), do: 0.90
  defp per_kg_rate(:usps), do: 0.70
  defp per_kg_rate(:lasership), do: 0.65
  defp per_kg_rate(_), do: 1.00
end
```
