```elixir
defmodule Logistics.Waypoint do
  @enforce_keys [:sequence, :address, :lat, :lng, :expected_arrival]
  defstruct [
    :sequence,
    :address,
    :lat,
    :lng,
    :expected_arrival,
    :notes,
    :contact_name,
    :contact_phone,
    :parcel_ids
  ]
end

defmodule Logistics.DriverProfile do
  @enforce_keys [:id, :name, :license_class]
  defstruct [:id, :name, :license_class, :certifications, :shift_start, :shift_end]
end

defmodule Logistics.VehicleTelemetry do
  defstruct [:vehicle_id, :make, :model, :fuel_level, :odometer_km, :last_service_at, :sensors]
end

defmodule Logistics.Route do
  @enforce_keys [:id, :driver, :vehicle, :waypoints]
  defstruct [:id, :driver, :vehicle, :waypoints, :status, :metadata]
end

defmodule Logistics.RouteStore do
  @moduledoc "Simulates loading full route snapshots from persistence."

  def load_pending_routes do
    Enum.map(1..500, fn i ->
      %Logistics.Route{
        id: "ROUTE-#{i}",
        driver: %Logistics.DriverProfile{
          id: "DRV-#{i}",
          name: "Driver #{i}",
          license_class: "C",
          certifications: ["hazmat", "refrigerated"],
          shift_start: ~T[06:00:00],
          shift_end: ~T[18:00:00]
        },
        vehicle: %Logistics.VehicleTelemetry{
          vehicle_id: "VEH-#{i}",
          make: "Mercedes",
          model: "Sprinter",
          fuel_level: 0.85,
          odometer_km: 120_000 + i * 10,
          last_service_at: ~D[2024-01-01],
          sensors: %{gps: true, temp: true, door: true}
        },
        waypoints: Enum.map(1..80, fn j ->
          %Logistics.Waypoint{
            sequence: j,
            address: "Street #{j}, City #{rem(j, 20)}",
            lat: -23.5 + j * 0.01,
            lng: -46.6 + j * 0.01,
            expected_arrival: Time.add(~T[08:00:00], j * 600, :second),
            notes: "Leave at door if absent",
            contact_name: "Contact #{j}",
            contact_phone: "+55119#{j}0000",
            parcel_ids: Enum.map(1..5, &"PKG-#{i}-#{j}-#{&1}")
          }
        end),
        status: :pending,
        metadata: %{region: "south", priority: rem(i, 3)}
      }
    end)
  end
end

defmodule Logistics.RouteWorker do
  use GenServer

  def start_link(worker_id) do
    GenServer.start_link(__MODULE__, %{id: worker_id, routes: []})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:assign_routes, routes}, state) do
    updated = %{state | routes: routes}
    {:noreply, updated}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{worker: state.id, route_count: length(state.routes)}, state}
  end
end

defmodule Logistics.DispatchCoordinator do
  @moduledoc "Splits pending routes across available worker processes."

  require Logger

  @spec assign_routes(pid(), list(Logistics.Route.t())) :: :ok
  def assign_routes(worker_pid, routes) do
    GenServer.cast(worker_pid, {:assign_routes, routes})
  end

  @spec dispatch_all() :: :ok
  def dispatch_all do
    all_routes = Logistics.RouteStore.load_pending_routes()

    chunks = Enum.chunk_every(all_routes, 50)

    workers =
      Enum.map(1..length(chunks), fn id ->
        {:ok, pid} = Logistics.RouteWorker.start_link(id)
        pid
      end)

    workers
    |> Enum.zip(chunks)
    |> Enum.each(fn {worker, chunk} ->
      Logger.info("Assigning #{length(chunk)} routes to worker #{inspect(worker)}")
      assign_routes(worker, chunk)
    end)

    :ok
  end
end
```
