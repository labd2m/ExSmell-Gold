```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Determines the appropriate carrier, service level, and shipping rate for outbound
  shipments based on weight, destination zone, declared value, and handling requirements.
  """

  alias Logistics.{Carrier, RateCalculator, LabelService, ShipmentLog}
  require Logger

  @domestic_countries ~w(US CA MX)
  @max_parcel_weight_kg 30.0

  def route(shipment_id) do
    with {:ok, shipment} <- ShipmentLog.fetch(shipment_id),
         {:ok, routing} <- route_shipment(shipment) do
      ShipmentLog.update_routing(shipment_id, routing)
      {:ok, routing}
    else
      {:error, :not_found} ->
        Logger.error("Shipment not found: #{shipment_id}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Routing failed for shipment=#{shipment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def route_shipment(%Shipment{
        service_level: service_level,
        weight_kg: weight_kg,
        origin: origin,
        destination: destination,
        dimensions: dimensions,
        declared_value: declared_value,
        requires_signature: requires_signature,
        hazmat: hazmat,
        fragile: fragile
      })
      when service_level == :express and weight_kg <= @max_parcel_weight_kg do
    carrier = Carrier.select(:express, origin.country, destination.country)
    rate = RateCalculator.compute(carrier, weight_kg, dimensions, declared_value)

    {:ok, label} =
      LabelService.generate(carrier, %{
        origin: origin,
        destination: destination,
        weight_kg: weight_kg,
        requires_signature: requires_signature,
        hazmat: hazmat,
        fragile: fragile
      })

    {:ok,
     %{
       carrier: carrier,
       service: :express,
       rate: rate,
       label: label,
       estimated_days: 1
     }}
  end

  def route_shipment(%Shipment{
        service_level: service_level,
        weight_kg: weight_kg,
        origin: origin,
        destination: destination,
        dimensions: dimensions,
        declared_value: declared_value,
        requires_signature: requires_signature,
        hazmat: hazmat,
        fragile: fragile
      })
      when service_level == :standard and weight_kg <= @max_parcel_weight_kg do
    zone = if destination.country in @domestic_countries, do: :domestic, else: :international
    carrier = Carrier.select(:standard, origin.country, destination.country)
    rate = RateCalculator.compute(carrier, weight_kg, dimensions, declared_value)

    {:ok, label} =
      LabelService.generate(carrier, %{
        origin: origin,
        destination: destination,
        weight_kg: weight_kg,
        requires_signature: requires_signature,
        hazmat: hazmat,
        fragile: fragile
      })

    estimated_days = if zone == :domestic, do: 5, else: 14

    {:ok,
     %{
       carrier: carrier,
       service: :standard,
       zone: zone,
       rate: rate,
       label: label,
       estimated_days: estimated_days
     }}
  end

  def route_shipment(%Shipment{
        service_level: service_level,
        weight_kg: weight_kg,
        origin: origin,
        destination: destination,
        dimensions: dimensions,
        declared_value: declared_value,
        requires_signature: requires_signature,
        hazmat: hazmat,
        fragile: fragile
      })
      when service_level == :freight or weight_kg > @max_parcel_weight_kg do
    carrier = Carrier.select(:freight, origin.country, destination.country)
    rate = RateCalculator.compute_freight(carrier, weight_kg, dimensions, declared_value)

    {:ok, label} =
      LabelService.generate_freight(carrier, %{
        origin: origin,
        destination: destination,
        weight_kg: weight_kg,
        requires_signature: requires_signature,
        hazmat: hazmat,
        fragile: fragile
      })

    {:ok,
     %{
       carrier: carrier,
       service: :freight,
       rate: rate,
       label: label,
       estimated_days: 10
     }}
  end


  def route_shipment(%Shipment{service_level: level, weight_kg: weight_kg}) do
    Logger.warning(
      "No routing rule matched: service_level=#{level} weight_kg=#{weight_kg}"
    )

    {:error, :no_routing_rule}
  end

  defp format_address(%{street: street, city: city, state: state, postal_code: zip, country: c}) do
    "#{street}, #{city}, #{state} #{zip}, #{c}"
  end
end
```
