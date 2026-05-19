```elixir
defmodule FleetAgent do
  @moduledoc "Shared Agent for fleet vehicle state and telemetry."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          vehicles: %{},
          telemetry: [],
          maintenance_schedule: []
        }
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

defmodule FleetRegistrar do
  @moduledoc "Registers new vehicles into the fleet."

  require Logger

  @vehicle_types [:truck, :van, :motorcycle, :sedan, :trailer]

  def add_vehicle(agent, %{id: id, plate: plate, type: type, capacity_kg: capacity} = attrs)
      when type in @vehicle_types do
    vehicle = %{
      id: id,
      plate: plate,
      type: type,
      capacity_kg: capacity,
      driver_id: Map.get(attrs, :driver_id),
      status: :available,
      odometer_km: Map.get(attrs, :odometer_km, 0),
      fuel_level_pct: 100,
      last_seen: nil,
      registered_at: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      %{state | vehicles: Map.put(state.vehicles, id, vehicle)}
    end)

    Logger.info("Registered vehicle #{id} (#{plate}) type=#{type}")
    {:ok, id}
  end

  def add_vehicle(_agent, attrs), do: {:error, {:invalid_vehicle_attrs, attrs}}
end
defmodule TelemetryIngester do
  @moduledoc "Processes GPS and sensor data from vehicle hardware."

  require Logger

  def ingest(agent, vehicle_id, %{lat: lat, lng: lng, speed_kmh: speed, fuel_pct: fuel} = reading) do
    timestamp = DateTime.utc_now()

    Agent.update(agent, fn state ->
      case Map.fetch(state.vehicles, vehicle_id) do
        :error ->
          Logger.warning("Telemetry for unknown vehicle #{vehicle_id}")
          state

        {:ok, vehicle} ->
          new_status =
            cond do
              speed > 0 -> :moving
              fuel < 10 -> :low_fuel
              true -> :idle
            end

          updated_vehicle = %{
            vehicle
            | status: new_status,
              fuel_level_pct: fuel,
              last_seen: timestamp,
              last_location: %{lat: lat, lng: lng}
          }

          telemetry_record = %{
            vehicle_id: vehicle_id,
            lat: lat,
            lng: lng,
            speed_kmh: speed,
            fuel_pct: fuel,
            timestamp: timestamp
          }

          %{
            state
            | vehicles: Map.put(state.vehicles, vehicle_id, updated_vehicle),
              telemetry: [telemetry_record | state.telemetry]
          }
      end
    end)

    :ok
  end
end
defmodule MaintenanceScheduler do
  @moduledoc "Schedules preventive and corrective vehicle maintenance."

  require Logger

  @maintenance_types [:oil_change, :tire_rotation, :brake_inspection, :full_service, :repair]

  def schedule(agent, vehicle_id, %{type: type, scheduled_at: scheduled_at} = details)
      when type in @maintenance_types do
    case Agent.get(agent, fn state -> Map.get(state.vehicles, vehicle_id) end) do
      nil ->
        {:error, :vehicle_not_found}

      _vehicle ->
        entry = %{
          id: :crypto.strong_rand_bytes(6) |> Base.encode16(),
          vehicle_id: vehicle_id,
          type: type,
          scheduled_at: scheduled_at,
          notes: Map.get(details, :notes, ""),
          status: :scheduled,
          created_at: DateTime.utc_now()
        }

        Agent.update(agent, fn state ->
          updated_vehicle =
            state.vehicles
            |> Map.get(vehicle_id)
            |> Map.put(:status, :maintenance_due)

          %{
            state
            | maintenance_schedule: [entry | state.maintenance_schedule],
              vehicles: Map.put(state.vehicles, vehicle_id, updated_vehicle)
          }
        end)

        Logger.info("Scheduled #{type} for vehicle #{vehicle_id} at #{scheduled_at}")
        {:ok, entry.id}
    end
  end
end
defmodule FleetMonitor do
  @moduledoc "Provides real-time fleet operational views."

  def vehicles_needing_attention(agent) do
    Agent.get(agent, fn state ->
      state.vehicles
      |> Map.values()
      |> Enum.filter(&(&1.status in [:low_fuel, :maintenance_due]))
      |> Enum.sort_by(& &1.status)
    end)
  end

  def active_vehicles(agent) do
    Agent.get(agent, fn state ->
      Enum.count(state.vehicles, fn {_id, v} -> v.status == :moving end)
    end)
  end

  def fleet_summary(agent) do
    Agent.get(agent, fn state ->
      by_status =
        state.vehicles
        |> Map.values()
        |> Enum.group_by(& &1.status)
        |> Map.new(fn {k, v} -> {k, length(v)} end)

      %{
        total: map_size(state.vehicles),
        by_status: by_status,
        telemetry_records: length(state.telemetry)
      }
    end)
  end
end
```
