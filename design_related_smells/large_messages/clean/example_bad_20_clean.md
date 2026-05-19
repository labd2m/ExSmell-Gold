```elixir
defmodule Logistics.Waypoint do
  @enforce_keys [:lat, :lon, :recorded_at]
  defstruct [:lat, :lon, :recorded_at, :speed_kmh, :heading]

  @type t :: %__MODULE__{
          lat: float(),
          lon: float(),
          recorded_at: DateTime.t(),
          speed_kmh: float() | nil,
          heading: float() | nil
        }
end

defmodule Logistics.Stop do
  @enforce_keys [:id, :address, :eta, :priority]
  defstruct [:id, :address, :eta, :priority, :notes, :packages, :signature_required]

  @type t :: %__MODULE__{
          id: String.t(),
          address: String.t(),
          eta: DateTime.t(),
          priority: :standard | :express | :same_day,
          notes: String.t() | nil,
          packages: [map()],
          signature_required: boolean()
        }
end

defmodule Logistics.Route do
  @enforce_keys [:id, :driver_id, :vehicle_id, :stops, :waypoints]
  defstruct [:id, :driver_id, :vehicle_id, :stops, :waypoints, :total_distance_km, :status]

  @type t :: %__MODULE__{
          id: String.t(),
          driver_id: String.t(),
          vehicle_id: String.t(),
          stops: [Logistics.Stop.t()],
          waypoints: [Logistics.Waypoint.t()],
          total_distance_km: float(),
          status: :planned | :in_progress | :completed
        }
end

defmodule Logistics.ManifestStore do
  @moduledoc "Retrieves the full daily manifest for all vehicles in the fleet."

  @spec fetch_daily_manifest(Date.t()) :: %{String.t() => Logistics.Route.t()}
  def fetch_daily_manifest(%Date{} = date) do
    now = DateTime.utc_now()

    Map.new(1..120, fn driver_n ->
      driver_id = "DRV-#{driver_n}"

      route = %Logistics.Route{
        id: "ROUTE-#{date}-#{driver_n}",
        driver_id: driver_id,
        vehicle_id: "VH-#{rem(driver_n, 60) + 1}",
        total_distance_km: :rand.uniform() * 200 + 50,
        status: :planned,
        stops:
          Enum.map(1..35, fn s ->
            %Logistics.Stop{
              id: "STOP-#{driver_n}-#{s}",
              address: "#{100 * s} Commerce Blvd, City #{rem(s, 20) + 1}, ST #{10000 + s}",
              eta: DateTime.add(now, s * 1200, :second),
              priority: Enum.random([:standard, :express, :same_day]),
              notes: "Leave at door if no answer. Reference #{:rand.uniform(999_999)}.",
              packages:
                Enum.map(1..5, fn p ->
                  %{
                    tracking: "PKG-#{driver_n}-#{s}-#{p}",
                    weight_kg: :rand.uniform() * 30,
                    dimensions: %{l: 40, w: 30, h: 20},
                    fragile: rem(p, 4) == 0
                  }
                end),
              signature_required: rem(s, 3) == 0
            }
          end),
        waypoints:
          Enum.map(1..500, fn w ->
            %Logistics.Waypoint{
              lat: -23.5 + :rand.uniform() * 2,
              lon: -46.6 + :rand.uniform() * 2,
              recorded_at: DateTime.add(now, w * 60, :second),
              speed_kmh: :rand.uniform() * 90,
              heading: :rand.uniform() * 360
            }
          end)
      }

      {driver_id, route}
    end)
  end
end

defmodule Logistics.DriverProcess do
  use GenServer

  def start_link(driver_id),
    do: GenServer.start_link(__MODULE__, driver_id, name: via(driver_id))

  defp via(id), do: {:via, Registry, {Logistics.DriverRegistry, id}}

  @impl true
  def init(driver_id), do: {:ok, %{driver_id: driver_id, route: nil}}

  @impl true
  def handle_info({:full_manifest, manifest}, state) do
    my_route = Map.get(manifest, state.driver_id)
    {:noreply, %{state | route: my_route}}
  end
end

defmodule Logistics.FleetCoordinator do
  @moduledoc """
  Loads the daily manifest and distributes it to all active driver processes.
  """

  require Logger

  @spec broadcast_route_manifest(Date.t(), [pid()]) :: :ok
  def broadcast_route_manifest(%Date{} = date, driver_pids) when is_list(driver_pids) do
    Logger.info("Loading full fleet manifest for #{date}...")

    manifest = Logistics.ManifestStore.fetch_daily_manifest(date)

    Logger.info(
      "Manifest loaded: #{map_size(manifest)} routes. Broadcasting to #{length(driver_pids)} drivers..."
    )

    Enum.each(driver_pids, fn pid ->
      send(pid, {:full_manifest, manifest})
    end)

    Logger.info("Broadcast complete.")
    :ok
  end
end
```
