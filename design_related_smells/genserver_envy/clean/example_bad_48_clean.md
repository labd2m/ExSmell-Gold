```elixir
defmodule ShipmentRegistry do
  @moduledoc """
  Maintains in-memory state for all active shipments in a regional
  logistics hub. Tracks shipment locations, statuses, carrier assignments,
  and delivery windows across the dispatch pipeline.
  """

  use Agent

  require Logger

  @type shipment :: %{
          id: String.t(),
          origin: {float(), float()},
          destination: {float(), float()},
          carrier_id: String.t() | nil,
          status: :pending | :assigned | :in_transit | :delivered | :failed,
          weight_kg: float(),
          priority: :standard | :express | :overnight,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          waypoints: list({float(), float()})
        }

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{shipments: %{}, carrier_loads: %{}} end, name: __MODULE__)
  end

  @doc "Registers a new shipment into the registry."
  def register_shipment(%{id: id} = shipment) do
    Agent.update(__MODULE__, fn state ->
      %{state | shipments: Map.put(state.shipments, id, shipment)}
    end)
  end

  @doc "Updates the status of a shipment."
  def update_status(shipment_id, new_status) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :shipments, fn shipments ->
        Map.update!(shipments, shipment_id, fn s ->
          %{s | status: new_status, updated_at: DateTime.utc_now()}
        end)
      end)
    end)
  end

  @doc "Assigns a carrier to a pending shipment."
  def assign_carrier(shipment_id, carrier_id) do
    Agent.update(__MODULE__, fn state ->
      updated_shipments =
        Map.update!(state.shipments, shipment_id, fn s ->
          %{s | carrier_id: carrier_id, status: :assigned, updated_at: DateTime.utc_now()}
        end)

      updated_loads =
        Map.update(state.carrier_loads, carrier_id, 1, &(&1 + 1))

      %{state | shipments: updated_shipments, carrier_loads: updated_loads}
    end)
  end

  @doc "Returns a shipment by ID."
  def get_shipment(shipment_id) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.shipments, shipment_id)
    end)
  end

  @doc "Lists all shipments with a given status."
  def list_by_status(status) do
    Agent.get(__MODULE__, fn state ->
      state.shipments
      |> Map.values()
      |> Enum.filter(&(&1.status == status))
    end)
  end


  @doc "Computes a greedy nearest-neighbour route for a shipment — isolated task."
  def compute_optimal_route(shipment_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.shipments, shipment_id) do
        nil ->
          {:error, :not_found}

        %{origin: origin, destination: dest, waypoints: waypoints} ->
          stops = [origin | waypoints] ++ [dest]

          route =
            stops
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.map(fn [{lat1, lon1}, {lat2, lon2}] ->
              dist = haversine_km(lat1, lon1, lat2, lon2)
              %{from: {lat1, lon1}, to: {lat2, lon2}, distance_km: Float.round(dist, 2)}
            end)

          total_km =
            route
            |> Enum.map(& &1.distance_km)
            |> Enum.sum()
            |> Float.round(2)

          {:ok, %{shipment_id: shipment_id, segments: route, total_km: total_km}}
      end
    end)
  end

  @doc "Estimates the delivery window based on priority and distance — isolated task."
  def estimate_delivery_window(shipment_id, avg_speed_kmh \\ 80.0) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.shipments, shipment_id) do
        nil ->
          {:error, :not_found}

        %{origin: {lat1, lon1}, destination: {lat2, lon2}, priority: priority} = s ->
          distance_km = haversine_km(lat1, lon1, lat2, lon2)
          transit_hours = distance_km / avg_speed_kmh

          buffer_hours =
            case priority do
              :overnight -> 0
              :express -> 4
              :standard -> 12
            end

          total_hours = transit_hours + buffer_hours
          base = s.created_at
          earliest = DateTime.add(base, floor(transit_hours * 3600), :second)
          latest = DateTime.add(base, floor(total_hours * 3600), :second)

          {:ok,
           %{
             shipment_id: shipment_id,
             priority: priority,
             distance_km: Float.round(distance_km, 2),
             earliest_delivery: earliest,
             latest_delivery: latest
           }}
      end
    end)
  end

  @doc "Generates a dispatch manifest for all assigned shipments of a carrier — isolated task."
  def generate_dispatch_manifest(carrier_id) do
    Agent.get(__MODULE__, fn state ->
      shipments =
        state.shipments
        |> Map.values()
        |> Enum.filter(&(&1.carrier_id == carrier_id and &1.status == :assigned))
        |> Enum.sort_by(fn s ->
          case s.priority do
            :overnight -> 0
            :express -> 1
            :standard -> 2
          end
        end)

      if Enum.empty?(shipments) do
        {:error, :no_assigned_shipments}
      else
        entries =
          Enum.map(shipments, fn s ->
            %{
              shipment_id: s.id,
              destination: s.destination,
              weight_kg: s.weight_kg,
              priority: s.priority
            }
          end)

        total_weight = shipments |> Enum.map(& &1.weight_kg) |> Enum.sum()

        {:ok,
         %{
           manifest_id: "MNF-#{:erlang.unique_integer([:positive])}",
           carrier_id: carrier_id,
           generated_at: DateTime.utc_now(),
           shipment_count: length(entries),
           total_weight_kg: Float.round(total_weight, 2),
           entries: entries
         }}
      end
    end)
  end


  defp haversine_km(lat1, lon1, lat2, lon2) do
    r = 6371.0
    dlat = :math.pi() / 180 * (lat2 - lat1)
    dlon = :math.pi() / 180 * (lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(:math.pi() / 180 * lat1) *
          :math.cos(:math.pi() / 180 * lat2) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end
end
```
