```elixir
defmodule Fleet.Vehicles.PositionTracker do
  @moduledoc """
  Tracks the most recent GPS position for each vehicle in a fleet.
  Positions are stored in ETS for fast concurrent reads.
  All writes are serialized through this GenServer.
  """

  use GenServer

  @table :vehicle_positions

  @type vehicle_id :: String.t()
  @type position :: %{
          lat: float(),
          lng: float(),
          heading_degrees: non_neg_integer(),
          speed_kmh: non_neg_integer(),
          recorded_at: DateTime.t()
        }

  @doc """
  Starts the PositionTracker linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Updates the stored position for `vehicle_id`.
  Returns `{:error, reason}` if the position map is malformed.
  """
  @spec update(vehicle_id(), map()) :: :ok | {:error, String.t()}
  def update(vehicle_id, raw_position)
      when is_binary(vehicle_id) and is_map(raw_position) do
    case parse_position(raw_position) do
      {:ok, position} ->
        GenServer.cast(__MODULE__, {:update, vehicle_id, position})

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns the last known position for `vehicle_id`.
  """
  @spec fetch(vehicle_id()) :: {:ok, position()} | {:error, :not_found}
  def fetch(vehicle_id) when is_binary(vehicle_id) do
    case :ets.lookup(@table, vehicle_id) do
      [{^vehicle_id, position}] -> {:ok, position}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns positions for all tracked vehicles.
  """
  @spec all() :: [{vehicle_id(), position()}]
  def all do
    :ets.tab2list(@table)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:update, vehicle_id, position}, state) do
    :ets.insert(@table, {vehicle_id, position})
    {:noreply, state}
  end

  defp parse_position(raw) do
    with {:ok, lat} <- fetch_float(raw, :lat),
         :ok <- validate_lat(lat),
         {:ok, lng} <- fetch_float(raw, :lng),
         :ok <- validate_lng(lng),
         {:ok, heading} <- fetch_non_neg_integer(raw, :heading_degrees),
         :ok <- validate_heading(heading),
         {:ok, speed} <- fetch_non_neg_integer(raw, :speed_kmh) do
      {:ok,
       %{
         lat: lat,
         lng: lng,
         heading_degrees: heading,
         speed_kmh: speed,
         recorded_at: DateTime.utc_now()
       }}
    end
  end

  defp fetch_float(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_float(v) -> {:ok, v}
      {:ok, v} when is_integer(v) -> {:ok, v * 1.0}
      {:ok, _} -> {:error, "#{key} must be a number"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp fetch_non_neg_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_integer(v) and v >= 0 -> {:ok, v}
      {:ok, _} -> {:error, "#{key} must be a non-negative integer"}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp validate_lat(lat) when lat >= -90.0 and lat <= 90.0, do: :ok
  defp validate_lat(_), do: {:error, "lat must be between -90 and 90"}

  defp validate_lng(lng) when lng >= -180.0 and lng <= 180.0, do: :ok
  defp validate_lng(_), do: {:error, "lng must be between -180 and 180"}

  defp validate_heading(h) when h >= 0 and h <= 360, do: :ok
  defp validate_heading(_), do: {:error, "heading_degrees must be between 0 and 360"}
end
```
