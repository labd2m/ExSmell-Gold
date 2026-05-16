```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Routes outbound shipments to the most appropriate carrier
  based on weight, destination, priority, and special handling flags.
  """

  require Logger

  @carriers %{
    express:   %{name: "FastFreight Express",   max_kg: 30,   rate_per_kg: 4.50},
    standard:  %{name: "NationalPost Standard", max_kg: 150,  rate_per_kg: 1.80},
    freight:   %{name: "HeavyHaul Freight",     max_kg: 5000, rate_per_kg: 0.95},
    secure:    %{name: "SecureCourier Plus",    max_kg: 50,   rate_per_kg: 6.20}
  }

  @type shipment :: %{
          id: String.t(),
          origin: String.t(),
          destination: String.t(),
          weight_kg: float(),
          declared_value: float(),
          optional(:priority) => :standard | :express | :overnight,
          optional(:insurance_required) => boolean(),
          optional(:fragile) => boolean(),
          optional(:hazmat) => boolean()
        }

  @spec route(shipment()) :: {:ok, map()} | {:error, String.t()}
  def route(shipment) do
    Logger.info("Routing shipment #{shipment.id} from #{shipment.origin} to #{shipment.destination}")

    with :ok                   <- validate_weight(shipment.weight_kg),
         {:ok, carrier_key}    <- select_carrier(shipment),
         {:ok, routing_result} <- build_routing_result(shipment, carrier_key) do
      {:ok, routing_result}
    end
  end

  defp validate_weight(kg) when kg <= 0, do: {:error, "weight must be positive"}
  defp validate_weight(kg) when kg > 5000, do: {:error, "shipment exceeds maximum allowable weight"}
  defp validate_weight(_), do: :ok

  defp select_carrier(shipment) do
    priority           = shipment[:priority]
    insurance_required = shipment[:insurance_required]
    fragile            = shipment[:fragile]
    hazmat             = shipment[:hazmat]

    cond do
      hazmat ->
        {:error, "hazmat shipments require manual routing"}

      insurance_required and shipment.declared_value > 5_000 ->
        {:ok, :secure}

      fragile and priority == :express ->
        {:ok, :secure}

      priority in [:express, :overnight] ->
        {:ok, :express}

      shipment.weight_kg > 150 ->
        {:ok, :freight}

      true ->
        {:ok, :standard}
    end
  end

  defp build_routing_result(shipment, carrier_key) do
    carrier = @carriers[carrier_key]

    if shipment.weight_kg > carrier.max_kg do
      {:error, "selected carrier #{carrier.name} cannot handle #{shipment.weight_kg} kg"}
    else
      cost = Float.round(shipment.weight_kg * carrier.rate_per_kg, 2)

      result = %{
        shipment_id:   shipment.id,
        carrier:       carrier.name,
        carrier_key:   carrier_key,
        origin:        shipment.origin,
        destination:   shipment.destination,
        weight_kg:     shipment.weight_kg,
        estimated_cost: cost,
        routed_at:     DateTime.utc_now()
      }

      {:ok, result}
    end
  end

  @spec estimate_cost(shipment(), atom()) :: float()
  def estimate_cost(shipment, carrier_key) do
    carrier = @carriers[carrier_key]
    Float.round(shipment.weight_kg * carrier.rate_per_kg, 2)
  end

  @spec available_carriers() :: [map()]
  def available_carriers do
    Enum.map(@carriers, fn {key, info} ->
      Map.put(info, :key, key)
    end)
  end
end
```
