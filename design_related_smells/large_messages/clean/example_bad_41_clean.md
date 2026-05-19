```elixir
defmodule TrackingAggregator do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{routes: %{}, event_count: 0}, opts)
  end

  def route_summary(pid, vehicle_id) do
    GenServer.call(pid, {:route_summary, vehicle_id})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:route_summary, vehicle_id}, _from, state) do
    summary = Map.get(state.routes, vehicle_id, %{points: 0, last_seen: nil})
    {:reply, summary, state}
  end

  @impl true
  def handle_info({:gps_batch, vehicle_id, events}, state) do
    Logger.info("Aggregator received #{length(events)} GPS events for vehicle=#{vehicle_id}")

    last_event = List.last(events)

    updated_routes =
      Map.update(
        state.routes,
        vehicle_id,
        %{points: length(events), last_seen: last_event.recorded_at},
        fn existing ->
          %{existing | points: existing.points + length(events), last_seen: last_event.recorded_at}
        end
      )

    {:noreply, %{state | routes: updated_routes, event_count: state.event_count + length(events)}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule TrackingIngester do
  require Logger

  @doc """
  Reads a batch of raw GPS frames from the vehicle telemetry buffer,
  parses them into structured events, then forwards the entire batch to
  the aggregator process for route reconstruction and alerting.
  """
  def ingest(aggregator_pid, vehicle_id) do
    Logger.info("TrackingIngester: reading telemetry buffer for vehicle=#{vehicle_id}")

    events = read_telemetry_buffer(vehicle_id)

    Logger.info("TrackingIngester: parsed #{length(events)} events — forwarding to aggregator")

    send(aggregator_pid, {:gps_batch, vehicle_id, events})

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate parsing a large GPS telemetry buffer
  # ---------------------------------------------------------------------------

  defp read_telemetry_buffer(vehicle_id) do
    base_lat = 37.7749 + :rand.uniform() * 0.1
    base_lng = -122.4194 + :rand.uniform() * 0.1

    Enum.map(1..20_000, fn n ->
      offset_s = n * 2

      %{
        vehicle_id: vehicle_id,
        sequence: n,
        lat: base_lat + :rand.uniform() * 0.001,
        lng: base_lng + :rand.uniform() * 0.001,
        altitude_m: 10 + :rand.uniform(500),
        speed_kmh: :rand.uniform(120),
        heading_deg: :rand.uniform(360),
        recorded_at: DateTime.add(~U[2024-06-01 00:00:00Z], offset_s, :second),
        telemetry: %{
          engine_rpm: 600 + :rand.uniform(5_400),
          fuel_level_pct: :rand.uniform(100),
          odometer_km: 50_000 + n,
          door_open: false,
          engine_temp_c: 80 + :rand.uniform(40),
          diagnostics: %{
            dtc_codes: [],
            battery_v: 12.0 + :rand.uniform() * 2,
            oil_pressure_psi: 30 + :rand.uniform(40)
          }
        }
      }
    end)
  end
end
```
