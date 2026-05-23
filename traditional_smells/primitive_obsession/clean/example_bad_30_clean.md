```elixir
defmodule Delivery.RouteOptimizer do
  @moduledoc """
  Optimises last-mile delivery routes for a fleet of couriers.
  Determines nearest depots, builds ordered waypoint lists,
  checks delivery zone coverage, and estimates travel times.
  """

  require Logger

  alias Delivery.Repo
  alias Delivery.Schema.{Depot, DeliveryZone, Order}

  @earth_radius_km 6_371.0
  @average_speed_kmh 40.0
  @max_route_orders 25


  @spec nearest_depot(float(), float()) :: {:ok, Depot.t()} | {:error, :no_depot_found}
  def nearest_depot(customer_lat, customer_lng)
      when is_float(customer_lat) and is_float(customer_lng) do
    depots = Repo.all(Depot)

    case Enum.min_by(depots, &haversine(customer_lat, customer_lng, &1.lat, &1.lng), fn -> nil end) do
      nil -> {:error, :no_depot_found}
      depot -> {:ok, depot}
    end
  end

  @spec build_route(float(), float()) :: {:ok, list(Order.t())} | {:error, term()}
  def build_route(depot_lat, depot_lng)
      when is_float(depot_lat) and is_float(depot_lng) do
    pending_orders =
      Repo.all(from o in Order, where: o.status == :pending, limit: @max_route_orders)

    if Enum.empty?(pending_orders) do
      {:error, :no_orders}
    else
      sorted =
        pending_orders
        |> Enum.sort_by(fn order ->
          haversine(depot_lat, depot_lng, order.delivery_lat, order.delivery_lng)
        end)

      Logger.info("Built route from depot=(#{depot_lat},#{depot_lng}) with #{length(sorted)} stops")
      {:ok, sorted}
    end
  end

  @spec within_delivery_zone?(float(), float(), String.t()) :: boolean()
  def within_delivery_zone?(lat, lng, zone_name)
      when is_float(lat) and is_float(lng) and is_binary(zone_name) do
    case Repo.get_by(DeliveryZone, name: zone_name) do
      nil ->
        false

      zone ->
        distance_km = haversine(lat, lng, zone.center_lat, zone.center_lng)
        distance_km <= zone.radius_km
    end
  end

  @spec estimate_travel_time(float(), float(), float()) :: {:ok, integer()} | {:error, term()}
  def estimate_travel_time(origin_lat, origin_lng, origin_lng_second)
      when is_float(origin_lat) and is_float(origin_lng) do
    orders = Repo.all(from o in Order, where: o.status == :pending)

    total_km =
      orders
      |> Enum.reduce({0.0, origin_lat, origin_lng}, fn order, {acc_km, prev_lat, prev_lng} ->
        leg_km = haversine(prev_lat, prev_lng, order.delivery_lat, order.delivery_lng)
        {acc_km + leg_km, order.delivery_lat, order.delivery_lng}
      end)
      |> elem(0)

    minutes = round(total_km / @average_speed_kmh * 60)
    {:ok, minutes}
  end

  @spec route_distance(list({float(), float()})) :: float()
  def route_distance(waypoints) when is_list(waypoints) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [{lat1, lng1}, {lat2, lng2}], acc ->
      acc + haversine(lat1, lng1, lat2, lng2)
    end)
    |> Float.round(2)
  end


  ## Private helpers — haversine formula

  defp haversine(lat1, lng1, lat2, lng2) do
    dlat = deg_to_rad(lat2 - lat1)
    dlng = deg_to_rad(lng2 - lng1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(deg_to_rad(lat1)) *
          :math.cos(deg_to_rad(lat2)) *
          :math.sin(dlng / 2) ** 2

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end
```