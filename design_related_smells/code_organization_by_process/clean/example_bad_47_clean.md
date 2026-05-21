```elixir
defmodule Logistics.RouteCalculator do
  use GenServer

  @moduledoc """
  Computes distances, fuel costs, and CO₂ emissions for delivery routes
  based on GPS waypoints. Used by the fleet management service to estimate
  operational costs before dispatching drivers.
  """


  @earth_radius_km 6_371.0

  @fuel_consumption_l_per_100km %{
    van:       9.5,
    truck:     28.0,
    motorbike: 4.0,
    bicycle:   0.0
  }

  @co2_per_litre_kg %{
    diesel:   2.68,
    petrol:   2.31,
    electric: 0.0
  }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns the great-circle distance in km between two `{lat, lon}` points.
  """
  def haversine_distance(pid, point_a, point_b) do
    GenServer.call(pid, {:haversine, point_a, point_b})
  end

  @doc """
  Returns the total distance in km for an ordered list of `waypoints`
  (each a `{lat, lon}` tuple).
  """
  def total_route_distance(pid, waypoints) do
    GenServer.call(pid, {:total_distance, waypoints})
  end

  @doc """
  Returns the estimated fuel cost for a route of `distance_km` using
  `vehicle_type` at `fuel_price_per_litre`.
  """
  def fuel_cost(pid, distance_km, vehicle_type, fuel_price_per_litre) do
    GenServer.call(pid, {:fuel_cost, distance_km, vehicle_type, fuel_price_per_litre})
  end

  @doc "Returns the estimated CO₂ emission in kg for the given distance and vehicle/fuel types."
  def co2_emission(pid, distance_km, vehicle_type, fuel_type) do
    GenServer.call(pid, {:co2, distance_km, vehicle_type, fuel_type})
  end

  @doc "Returns a full route summary map combining distance, fuel cost, and emissions."
  def route_summary(pid, waypoints, vehicle_type, fuel_type, fuel_price) do
    GenServer.call(pid, {:route_summary, waypoints, vehicle_type, fuel_type, fuel_price})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:haversine, {lat1, lon1}, {lat2, lon2}}, _from, state) do
    dist = do_haversine(lat1, lon1, lat2, lon2)
    {:reply, {:ok, Float.round(dist, 3)}, state}
  end

  def handle_call({:total_distance, waypoints}, _from, state) when length(waypoints) < 2 do
    {:reply, {:ok, 0.0}, state}
  end

  def handle_call({:total_distance, waypoints}, _from, state) do
    total =
      waypoints
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(0.0, fn [{lat1, lon1}, {lat2, lon2}], acc ->
        acc + do_haversine(lat1, lon1, lat2, lon2)
      end)

    {:reply, {:ok, Float.round(total, 3)}, state}
  end

  def handle_call({:fuel_cost, distance_km, vehicle_type, price_per_l}, _from, state) do
    result =
      case Map.get(@fuel_consumption_l_per_100km, vehicle_type) do
        nil -> {:error, :unknown_vehicle_type}
        lp100 ->
          litres = distance_km * lp100 / 100
          {:ok, Float.round(litres * price_per_l, 2)}
      end

    {:reply, result, state}
  end

  def handle_call({:co2, distance_km, vehicle_type, fuel_type}, _from, state) do
    with {:ok, lp100}       <- Map.fetch(@fuel_consumption_l_per_100km, vehicle_type),
         {:ok, co2_per_l}   <- Map.fetch(@co2_per_litre_kg, fuel_type) do
      litres = distance_km * lp100 / 100
      {:reply, {:ok, Float.round(litres * co2_per_l, 3)}, state}
    else
      :error -> {:reply, {:error, :unknown_vehicle_or_fuel_type}, state}
    end
  end

  def handle_call({:route_summary, waypoints, vehicle_type, fuel_type, fuel_price}, _from, state) do
    case length(waypoints) do
      n when n < 2 ->
        {:reply, {:error, :insufficient_waypoints}, state}
      _ ->
        total_km =
          waypoints
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.reduce(0.0, fn [{la1, lo1}, {la2, lo2}], acc ->
            acc + do_haversine(la1, lo1, la2, lo2)
          end)

        lp100     = Map.get(@fuel_consumption_l_per_100km, vehicle_type, 0.0)
        co2_per_l = Map.get(@co2_per_litre_kg, fuel_type, 0.0)
        litres    = total_km * lp100 / 100

        summary = %{
          distance_km:     Float.round(total_km, 3),
          fuel_litres:     Float.round(litres, 2),
          fuel_cost:       Float.round(litres * fuel_price, 2),
          co2_kg:          Float.round(litres * co2_per_l, 3),
          waypoint_count:  length(waypoints)
        }

        {:reply, {:ok, summary}, state}
    end
  end

  ## Private helpers

  defp do_haversine(lat1, lon1, lat2, lon2) do
    r  = @earth_radius_km
    d_lat = :math.pi() / 180 * (lat2 - lat1)
    d_lon = :math.pi() / 180 * (lon2 - lon1)
    a =
      :math.sin(d_lat / 2) ** 2 +
      :math.cos(:math.pi() / 180 * lat1) *
      :math.cos(:math.pi() / 180 * lat2) *
      :math.sin(d_lon / 2) ** 2
    2 * r * :math.asin(:math.sqrt(a))
  end

end
```
