# Annotated Example — Agent Obsession

| Field | Value |
|---|---|
| **Smell name** | Agent Obsession |
| **Expected smell location** | Multiple modules: `LogisticsDispatch`, `LogisticsTracking`, `LogisticsETA`, `LogisticsReporting` |
| **Affected functions** | `LogisticsDispatch.assign/3`, `LogisticsTracking.update_position/3`, `LogisticsETA.estimate/2`, `LogisticsReporting.daily_summary/2` |
| **Short explanation** | Four logistics modules each interact directly with an Agent holding shipment and driver state. No central boundary governs who can read or write the agent; the internal state shape is implicitly shared across all modules. |

```elixir
defmodule LogisticsAgentStore do
  @moduledoc "Initializes the shared logistics dispatch agent."

  def start do
    {:ok, pid} = Agent.start_link(fn ->
      %{shipments: %{}, drivers: %{}, positions: %{}, events: []}
    end)
    pid
  end
end

defmodule LogisticsDispatch do
  @moduledoc """
  Assigns shipments to drivers in the logistics agent.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because LogisticsDispatch directly calls Agent.update/2
  # to write shipment and driver state. It owns a portion of the agent's internal structure
  # independently, without going through any encapsulated owner module.
  def assign(pid, shipment_id, driver_id, route) do
    shipment = %{
      id: shipment_id,
      driver_id: driver_id,
      route: route,
      status: :dispatched,
      dispatched_at: DateTime.utc_now()
    }

    Agent.update(pid, fn state ->
      updated_shipments = Map.put(state.shipments, shipment_id, shipment)
      updated_drivers = Map.update(state.drivers, driver_id, [shipment_id], fn list ->
        [shipment_id | list]
      end)

      event = %{type: :dispatched, shipment_id: shipment_id, driver_id: driver_id, at: DateTime.utc_now()}

      %{state |
        shipments: updated_shipments,
        drivers: updated_drivers,
        events: [event | state.events]
      }
    end)

    :ok
  end

  def shipment_status(pid, shipment_id) do
    Agent.get(pid, fn state ->
      case Map.get(state.shipments, shipment_id) do
        nil -> {:error, :not_found}
        s   -> {:ok, s.status}
      end
    end)
  end
  # VALIDATION: SMELL END
end

defmodule LogisticsTracking do
  @moduledoc """
  Updates GPS positions for active deliveries.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because LogisticsTracking directly calls Agent.update/2,
  # making it a second module that writes directly into the agent state. The `positions`
  # and `events` keys are accessed without any centralized ownership.
  def update_position(pid, shipment_id, coordinates) do
    Agent.update(pid, fn state ->
      position = %{
        shipment_id: shipment_id,
        lat: coordinates[:lat],
        lng: coordinates[:lng],
        recorded_at: DateTime.utc_now()
      }

      event = %{type: :position_update, shipment_id: shipment_id, coordinates: coordinates, at: DateTime.utc_now()}

      %{state |
        positions: Map.put(state.positions, shipment_id, position),
        events: [event | state.events]
      }
    end)

    :ok
  end

  def current_position(pid, shipment_id) do
    Agent.get(pid, fn state -> Map.get(state.positions, shipment_id) end)
  end

  def active_shipments(pid) do
    Agent.get(pid, fn state ->
      Map.keys(state.positions)
    end)
  end
  # VALIDATION: SMELL END
end

defmodule LogisticsETA do
  @moduledoc """
  Estimates time of arrival for shipments based on current position.
  """

  @avg_speed_kmh 60.0

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because LogisticsETA is a third module directly calling
  # Agent.get/2 to read both `positions` and `shipments` fields. It implicitly depends on
  # the same internal structure used by the other modules, tightening the coupling.
  def estimate(pid, shipment_id) do
    {position, shipment} =
      Agent.get(pid, fn state ->
        {Map.get(state.positions, shipment_id), Map.get(state.shipments, shipment_id)}
      end)

    case {position, shipment} do
      {nil, _} -> {:error, :no_position}
      {_, nil} -> {:error, :shipment_not_found}
      {pos, ship} ->
        distance = haversine_km(pos.lat, pos.lng, ship.route[:dest_lat], ship.route[:dest_lng])
        eta_hours = distance / @avg_speed_kmh
        eta_minutes = round(eta_hours * 60)
        {:ok, %{shipment_id: shipment_id, eta_minutes: eta_minutes, distance_km: Float.round(distance, 2)}}
    end
  end

  defp haversine_km(lat1, lng1, lat2, lng2) do
    r = 6371.0
    dlat = (lat2 - lat1) * :math.pi() / 180
    dlng = (lng2 - lng1) * :math.pi() / 180
    a = :math.sin(dlat / 2) ** 2 + :math.cos(lat1 * :math.pi() / 180) * :math.cos(lat2 * :math.pi() / 180) * :math.sin(dlng / 2) ** 2
    2 * r * :math.asin(:math.sqrt(a))
  end
  # VALIDATION: SMELL END
end

defmodule LogisticsReporting do
  @moduledoc """
  Generates logistics summary reports from the shared dispatch agent.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because LogisticsReporting is a fourth module that reads
  # the full agent state via Agent.get/2. All four modules now share implicit knowledge
  # of the agent's structure, making any change to it a system-wide refactoring task.
  def daily_summary(pid, date) do
    state = Agent.get(pid, fn s -> s end)

    dispatched_today =
      Enum.filter(state.shipments, fn {_k, s} ->
        Date.compare(DateTime.to_date(s.dispatched_at), date) == :eq
      end)

    events_today =
      Enum.filter(state.events, fn e ->
        Date.compare(DateTime.to_date(e.at), date) == :eq
      end)

    %{
      date: date,
      total_dispatched: length(dispatched_today),
      active_drivers: map_size(state.drivers),
      tracked_positions: map_size(state.positions),
      total_events: length(events_today)
    }
  end
  # VALIDATION: SMELL END
end
```
