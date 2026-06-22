```elixir
defmodule Logistics.Routes.Optimizer do
  @moduledoc """
  Computes optimized delivery routes for a fleet of vehicles given a set
  of stops. Implements a greedy nearest-neighbor heuristic as a baseline
  strategy. All functions are pure and free of side effects.
  """

  alias Logistics.Routes.{Stop, Route, Vehicle}

  @type optimization_opts :: [max_stops_per_vehicle: pos_integer(), depot: Stop.t()]

  @doc """
  Distributes `stops` across `vehicles` and returns optimized per-vehicle routes.

  Options:
  - `:max_stops_per_vehicle` — maximum stops assignable to one vehicle (default: 20)
  - `:depot` — starting and ending location for all vehicles (required)
  """
  @spec optimize([Stop.t()], [Vehicle.t()], optimization_opts()) ::
          {:ok, [Route.t()]} | {:error, :no_vehicles | :missing_depot}
  def optimize(_stops, [], _opts), do: {:error, :no_vehicles}

  def optimize(stops, vehicles, opts) do
    case Keyword.fetch(opts, :depot) do
      {:ok, %Stop{} = depot} ->
        max_stops = Keyword.get(opts, :max_stops_per_vehicle, 20)
        routes = assign_and_sequence(stops, vehicles, depot, max_stops)
        {:ok, routes}

      _ ->
        {:error, :missing_depot}
    end
  end

  @doc "Calculates the total distance of a route in kilometers."
  @spec total_distance(Route.t()) :: float()
  def total_distance(%Route{stops: stops}) when length(stops) < 2, do: 0.0

  def total_distance(%Route{stops: stops}) do
    stops
    |> Enum.zip(tl(stops))
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + haversine(a, b) end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec assign_and_sequence([Stop.t()], [Vehicle.t()], Stop.t(), pos_integer()) :: [Route.t()]
  defp assign_and_sequence(stops, vehicles, depot, max_stops) do
    chunks = Enum.chunk_every(stops, max_stops)

    vehicles
    |> Enum.zip(chunks)
    |> Enum.map(fn {vehicle, chunk} ->
      sequenced = nearest_neighbor(depot, chunk)
      %Route{vehicle: vehicle, stops: [depot | sequenced] ++ [depot]}
    end)
  end

  @spec nearest_neighbor(Stop.t(), [Stop.t()]) :: [Stop.t()]
  defp nearest_neighbor(_current, []), do: []

  defp nearest_neighbor(current, remaining) do
    nearest = Enum.min_by(remaining, &haversine(current, &1))
    rest = List.delete(remaining, nearest)
    [nearest | nearest_neighbor(nearest, rest)]
  end

  @spec haversine(Stop.t(), Stop.t()) :: float()
  defp haversine(%Stop{lat: lat1, lng: lng1}, %Stop{lat: lat2, lng: lng2}) do
    r = 6_371.0
    dlat = to_rad(lat2 - lat1)
    dlng = to_rad(lng2 - lng1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(to_rad(lat1)) * :math.cos(to_rad(lat2)) * :math.sin(dlng / 2) ** 2

    2 * r * :math.asin(:math.sqrt(a))
  end

  @spec to_rad(float()) :: float()
  defp to_rad(degrees), do: degrees * :math.pi() / 180.0
end

defmodule Logistics.Routes.Stop do
  @moduledoc "A geographic stop in a delivery route."

  @enforce_keys [:id, :lat, :lng]
  defstruct [:id, :lat, :lng, :address, :time_window]

  @type t :: %__MODULE__{
          id: String.t(),
          lat: float(),
          lng: float(),
          address: String.t() | nil,
          time_window: {Time.t(), Time.t()} | nil
        }
end

defmodule Logistics.Routes.Route do
  @moduledoc "An ordered sequence of stops assigned to a vehicle."

  defstruct [:vehicle, :stops]

  @type t :: %__MODULE__{
          vehicle: Logistics.Routes.Vehicle.t(),
          stops: [Logistics.Routes.Stop.t()]
        }
end
```
