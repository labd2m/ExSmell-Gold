# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `Logistics.ShipmentPlanner` module — address parameters across all public functions |
| **Affected functions** | `plan_route/2`, `estimate_delivery/3`, `validate_address/1`, `assign_carrier/2` |
| **Short explanation** | Origin and destination addresses are passed as plain `String.t()` values (free-form strings) rather than a structured `%Address{street: _, city: _, state: _, zip: _, country: _}` type. This forces repeated parsing logic, makes validation scattered, prevents compile-time guarantees about address fields, and hides domain knowledge inside opaque strings. |

```elixir
defmodule Logistics.ShipmentPlanner do
  @moduledoc """
  Plans shipment routes, estimates delivery windows, validates delivery
  addresses, and assigns carriers for outbound logistics operations.
  """

  require Logger

  alias Logistics.Repo
  alias Logistics.Schema.{Shipment, Carrier, Route}
  alias Logistics.GeoService

  @default_transit_days 3
  @express_cutoff_km 500

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because `origin` and `destination` are plain
  # binary strings like "123 Main St, Springfield, IL 62701, US" instead of
  # a dedicated %Address{} struct. All functions must re-parse the string
  # to extract city, state, zip, and country, spreading fragile string
  # manipulation throughout the module.

  @spec plan_route(String.t(), String.t()) ::
          {:ok, Route.t()} | {:error, term()}
  def plan_route(origin, destination)
      when is_binary(origin) and is_binary(destination) do
    with {:ok, origin_coords} <- GeoService.geocode(origin),
         {:ok, dest_coords} <- GeoService.geocode(destination),
         distance_km <- GeoService.haversine_km(origin_coords, dest_coords),
         {:ok, carrier} <- assign_carrier(distance_km, origin),
         route_attrs <- build_route_attrs(origin, destination, distance_km, carrier) do
      %Route{}
      |> Route.changeset(route_attrs)
      |> Repo.insert()
    end
  end

  @spec estimate_delivery(String.t(), String.t(), atom()) ::
          {:ok, Date.t()} | {:error, term()}
  def estimate_delivery(origin, destination, service_level)
      when is_binary(origin) and is_binary(destination) do
    with {:ok, origin_coords} <- GeoService.geocode(origin),
         {:ok, dest_coords} <- GeoService.geocode(destination),
         distance_km <- GeoService.haversine_km(origin_coords, dest_coords) do
      transit_days =
        case service_level do
          :express when distance_km <= @express_cutoff_km -> 1
          :express -> 2
          :standard -> @default_transit_days
          :economy -> 5
        end

      delivery_date = Date.add(Date.utc_today(), transit_days)
      Logger.info("Estimated delivery from #{origin} to #{destination}: #{delivery_date}")
      {:ok, delivery_date}
    end
  end

  @spec validate_address(String.t()) :: :ok | {:error, term()}
  def validate_address(address) when is_binary(address) do
    parts = String.split(address, ",") |> Enum.map(&String.trim/1)

    cond do
      length(parts) < 3 ->
        {:error, {:invalid_address, "expected at least street, city, state/zip"}}

      String.length(List.last(parts)) != 2 ->
        {:error, {:invalid_address, "country code must be 2 characters"}}

      true ->
        case GeoService.validate(address) do
          {:ok, _normalized} -> :ok
          {:error, reason} -> {:error, {:unresolvable_address, reason}}
        end
    end
  end

  @spec assign_carrier(float(), String.t()) :: {:ok, Carrier.t()} | {:error, term()}
  def assign_carrier(distance_km, origin_address)
      when is_float(distance_km) and is_binary(origin_address) do
    [_street, city_state | _] = String.split(origin_address, ",") |> Enum.map(&String.trim/1)
    region = extract_region(city_state)

    carriers =
      Repo.all(
        from c in Carrier,
          where: c.active == true and c.region == ^region,
          order_by: [asc: c.base_rate]
      )

    case Enum.find(carriers, &(&1.max_distance_km >= distance_km)) do
      nil -> {:error, :no_carrier_available}
      carrier -> {:ok, carrier}
    end
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp build_route_attrs(origin, destination, distance_km, carrier) do
    %{
      origin_address: origin,
      destination_address: destination,
      distance_km: distance_km,
      carrier_id: carrier.id,
      estimated_transit_days: transit_days_for_distance(distance_km),
      status: :planned,
      created_at: DateTime.utc_now()
    }
  end

  defp transit_days_for_distance(km) when km <= 100, do: 1
  defp transit_days_for_distance(km) when km <= 500, do: 2
  defp transit_days_for_distance(_km), do: @default_transit_days

  defp extract_region(city_state) do
    city_state
    |> String.split(" ")
    |> List.last()
    |> String.slice(0, 2)
    |> String.upcase()
  end
end
```
