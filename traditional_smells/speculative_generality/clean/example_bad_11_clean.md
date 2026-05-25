```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Computes optimal delivery routes for single and multi-stop shipments.
  Uses a distance matrix and heuristic algorithms to minimise travel time.
  Integrates with the fleet management system for live vehicle availability.
  """

  alias Logistics.{Route, Stop, Vehicle, DistanceMatrix, Repo}

  @max_stops_per_route 25
  @default_depot       "DEPOT_CENTRAL"

  def optimize(origin, stops, mode \\ :fastest) do
    if length(stops) > @max_stops_per_route do
      {:error, :too_many_stops}
    else
      matrix   = DistanceMatrix.fetch!(origin, stops)
      ordered  = nearest_neighbour(origin, stops, matrix)
      distance = total_distance(ordered, matrix)
      eta      = estimate_eta(distance)

      route_attrs = %{
        origin:       origin,
        stops:        ordered,
        mode:         mode,
        total_km:     Float.round(distance, 1),
        estimated_eta: eta,
        optimized_at: DateTime.utc_now()
      }

      case Route.changeset(%Route{}, route_attrs) |> Repo.insert() do
        {:ok, route} -> {:ok, route}
        {:error, cs} -> {:error, cs}
      end
    end
  end

  def plan_multi_stop(depot, delivery_stops) do
    chunked = Enum.chunk_every(delivery_stops, @max_stops_per_route)

    Enum.map(chunked, fn chunk ->
      case optimize(depot, chunk) do
        {:ok, route}     -> {:ok, route}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def replan_on_delay(route_id) do
    route        = Repo.get!(Route, route_id)
    remaining    = Enum.reject(route.stops, &(&1.completed))

    case optimize(route.current_position, remaining) do
      {:ok, new_route} ->
        route
        |> Route.changeset(%{status: :replanned, replanned_route_id: new_route.id})
        |> Repo.update()

        {:ok, new_route}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def assign_vehicle(route_id, vehicle_id) do
    route   = Repo.get!(Route, route_id)
    vehicle = Repo.get!(Vehicle, vehicle_id)

    if vehicle.status != :available do
      {:error, :vehicle_unavailable}
    else
      Repo.transaction(fn ->
        route
        |> Route.changeset(%{vehicle_id: vehicle_id, status: :assigned})
        |> Repo.update!()

        vehicle
        |> Vehicle.changeset(%{status: :on_route, current_route_id: route_id})
        |> Repo.update!()
      end)
    end
  end

  def complete_stop(route_id, stop_id, proof_of_delivery) do
    route = Repo.get!(Route, route_id)
    stop  = Enum.find(route.stops, &(&1.id == stop_id))

    if is_nil(stop) do
      {:error, :stop_not_found}
    else
      updated_stops =
        Enum.map(route.stops, fn s ->
          if s.id == stop_id do
            %Stop{s | completed: true, pod: proof_of_delivery, completed_at: DateTime.utc_now()}
          else
            s
          end
        end)

      route
      |> Route.changeset(%{stops: updated_stops})
      |> Repo.update()
    end
  end

  def route_status(route_id) do
    route = Repo.get!(Route, route_id)

    total     = length(route.stops)
    completed = Enum.count(route.stops, & &1.completed)
    remaining = total - completed

    %{
      route_id:      route.id,
      total_stops:   total,
      completed:     completed,
      remaining:     remaining,
      progress_pct:  if(total > 0, do: Float.round(completed / total * 100, 1), else: 0.0),
      status:        route.status
    }
  end


  defp nearest_neighbour(origin, stops, matrix) do
    Enum.reduce(stops, {origin, []}, fn _, {current, ordered} ->
      remaining = stops -- ordered
      next      = Enum.min_by(remaining, &matrix[current][&1.id])
      {next.id, ordered ++ [next]}
    end)
    |> elem(1)
  end

  defp total_distance(stops, matrix) do
    stops
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc -> acc + matrix[a.id][b.id] end)
  end

  defp estimate_eta(distance_km) do
    avg_speed_kmh = 50
    minutes       = round(distance_km / avg_speed_kmh * 60)
    DateTime.add(DateTime.utc_now(), minutes * 60, :second)
  end
end
```
