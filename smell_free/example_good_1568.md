```elixir
defmodule Fleet.Vehicles.TelematicsAggregator do
  @moduledoc """
  Aggregates real-time vehicle telemetry streams for fleet management.

  Maintains a per-vehicle state summary updated by incoming telemetry events,
  with configurable alert thresholds and periodic snapshot persistence.
  """

  use GenServer, restart: :permanent

  alias Fleet.Vehicles.{TelemetryEvent, VehicleState, AlertDispatcher, SnapshotStore}

  @snapshot_interval_ms 30_000

  @type state :: %{
          vehicles: %{String.t() => VehicleState.t()},
          alert_thresholds: map()
        }

  @doc """
  Starts the telematics aggregator under a supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ingests a telemetry event for the specified vehicle.
  """
  @spec ingest(TelemetryEvent.t()) :: :ok
  def ingest(%TelemetryEvent{} = event) do
    GenServer.cast(__MODULE__, {:ingest, event})
  end

  @doc """
  Returns the current aggregated state for a vehicle.
  """
  @spec vehicle_state(String.t()) :: {:ok, VehicleState.t()} | {:error, :not_found}
  def vehicle_state(vehicle_id) when is_binary(vehicle_id) do
    GenServer.call(__MODULE__, {:vehicle_state, vehicle_id})
  end

  @impl GenServer
  def init(opts) do
    thresholds = Keyword.get(opts, :alert_thresholds, default_thresholds())
    schedule_snapshot()
    {:ok, %{vehicles: %{}, alert_thresholds: thresholds}}
  end

  @impl GenServer
  def handle_cast({:ingest, %TelemetryEvent{vehicle_id: vid} = event}, state) do
    current = Map.get(state.vehicles, vid, VehicleState.empty(vid))
    updated = VehicleState.apply_event(current, event)
    new_vehicles = Map.put(state.vehicles, vid, updated)
    new_state = %{state | vehicles: new_vehicles}
    evaluate_alerts(updated, state.alert_thresholds)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call({:vehicle_state, vehicle_id}, _from, state) do
    result =
      case Map.fetch(state.vehicles, vehicle_id) do
        {:ok, vehicle_state} -> {:ok, vehicle_state}
        :error -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:persist_snapshots, state) do
    persist_all_snapshots(state.vehicles)
    schedule_snapshot()
    {:noreply, state}
  end

  defp evaluate_alerts(%VehicleState{speed_kmh: speed, fuel_pct: fuel} = vs, thresholds) do
    check_threshold(vs.vehicle_id, :overspeed, speed, thresholds.max_speed_kmh)
    check_threshold(vs.vehicle_id, :low_fuel, fuel, thresholds.min_fuel_pct, :below)
  end

  defp check_threshold(vehicle_id, alert_type, value, threshold, direction \\ :above) do
    triggered =
      case direction do
        :above -> value > threshold
        :below -> value < threshold
      end

    if triggered do
      AlertDispatcher.dispatch(%{
        vehicle_id: vehicle_id,
        alert_type: alert_type,
        value: value,
        threshold: threshold
      })
    end
  end

  defp persist_all_snapshots(vehicles) do
    vehicles
    |> Map.values()
    |> Enum.each(&SnapshotStore.save/1)
  end

  defp default_thresholds do
    %{max_speed_kmh: 130, min_fuel_pct: 10}
  end

  defp schedule_snapshot do
    Process.send_after(self(), :persist_snapshots, @snapshot_interval_ms)
  end
end
```
