```elixir
defmodule MyApp.ShipmentTrackerTask do
  @moduledoc """
  Tracks real-time location and status of shipments in transit.
  Provides ETA calculations and delivers milestone notifications.
  """

  alias MyApp.{GeoService, NotificationService}
  alias MyApp.Logistics.{Shipment, Waypoint, Milestone}

  @eta_speed_kmh 80
  @milestone_radius_km 5.0

  def start_tracker(shipment) do
    Task.start_link(fn ->
      state = %{
        shipment: shipment,
        current_location: shipment.origin,
        waypoints: [],
        milestones_triggered: MapSet.new(),
        started_at: DateTime.utc_now()
      }

      tracker_loop(state)
    end)
  end

  defp tracker_loop(state) do
    receive do
      {:update_location, from, coords} ->
        distance_to_dest =
          GeoService.haversine_km(coords, state.shipment.destination)

        eta_hours = distance_to_dest / @eta_speed_kmh

        waypoint = %Waypoint{
          coords: coords,
          recorded_at: DateTime.utc_now(),
          distance_remaining_km: distance_to_dest
        }

        new_milestones =
          check_milestones(state.shipment.milestones, coords, state.milestones_triggered)

        Enum.each(new_milestones, fn milestone ->
          NotificationService.notify(state.shipment.recipient_id, :milestone, milestone)
        end)

        new_triggered = MapSet.union(state.milestones_triggered, MapSet.new(new_milestones))

        new_state = %{
          state
          | current_location: coords,
            waypoints: [waypoint | state.waypoints],
            milestones_triggered: new_triggered
        }

        send(from, {:ok, %{eta_hours: eta_hours, waypoint: waypoint}})
        tracker_loop(new_state)

      {:get_status, from} ->
        status = %{
          shipment_id: state.shipment.id,
          current_location: state.current_location,
          waypoints_count: length(state.waypoints),
          milestones_triggered: MapSet.to_list(state.milestones_triggered),
          started_at: state.started_at
        }
        send(from, {:ok, status})
        tracker_loop(state)

      {:mark_delivered, from} ->
        NotificationService.notify(state.shipment.recipient_id, :delivered, state.shipment)
        send(from, :ok)

      {:reroute, from, new_destination} ->
        updated_shipment = %{state.shipment | destination: new_destination}
        send(from, {:ok, :rerouted})
        tracker_loop(%{state | shipment: updated_shipment})

      :stop ->
        :ok
    after
      30_000 ->
        tracker_loop(state)
    end
  end


  defp check_milestones(milestones, current_coords, already_triggered) do
    milestones
    |> Enum.reject(&MapSet.member?(already_triggered, &1.id))
    |> Enum.filter(fn milestone ->
      GeoService.haversine_km(current_coords, milestone.coords) <= @milestone_radius_km
    end)
  end

  def update_location(pid, coords) do
    send(pid, {:update_location, self(), coords})

    receive do
      {:ok, info} -> {:ok, info}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def get_status(pid) do
    send(pid, {:get_status, self()})

    receive do
      {:ok, status} -> {:ok, status}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def mark_delivered(pid) do
    send(pid, {:mark_delivered, self()})

    receive do
      :ok -> :ok
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
