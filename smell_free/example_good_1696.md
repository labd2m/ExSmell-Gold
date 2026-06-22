```elixir
defmodule Fleet.VehicleAggregate do
  @moduledoc """
  Aggregate root for fleet vehicle state, tracking location history,
  service intervals, and operational status changes.
  """

  @type coordinates :: %{lat: float(), lng: float()}
  @type status :: :available | :in_service | :maintenance | :retired
  @type location_entry :: %{coordinates: coordinates(), recorded_at: DateTime.t()}

  @type t :: %__MODULE__{
    id: String.t(),
    plate: String.t(),
    status: status(),
    odometer_km: non_neg_integer(),
    location_history: [location_entry()],
    last_service_km: non_neg_integer(),
    service_interval_km: pos_integer()
  }

  defstruct [
    :id, :plate, :status, :odometer_km,
    :location_history, :last_service_km, :service_interval_km
  ]

  @spec new(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(id, plate, opts \\ [])
      when is_binary(id) and is_binary(plate) do
    with :ok <- validate_plate(plate) do
      vehicle = %__MODULE__{
        id: id,
        plate: String.upcase(plate),
        status: :available,
        odometer_km: Keyword.get(opts, :odometer_km, 0),
        location_history: [],
        last_service_km: Keyword.get(opts, :last_service_km, 0),
        service_interval_km: Keyword.get(opts, :service_interval_km, 10_000)
      }
      {:ok, vehicle}
    end
  end

  @spec update_location(t(), coordinates()) :: {:ok, t()} | {:error, String.t()}
  def update_location(%__MODULE__{status: :retired}, _coords) do
    {:error, "Cannot update location of a retired vehicle"}
  end

  def update_location(%__MODULE__{} = vehicle, %{lat: lat, lng: lng} = coords)
      when is_float(lat) and is_float(lng) do
    entry = %{coordinates: coords, recorded_at: DateTime.utc_now()}
    updated = %{vehicle | location_history: [entry | vehicle.location_history]}
    {:ok, updated}
  end

  def update_location(_, _), do: {:error, "Invalid coordinates"}

  @spec log_distance(t(), pos_integer()) :: {:ok, t()} | {:error, String.t()}
  def log_distance(%__MODULE__{status: status}, _km) when status in [:maintenance, :retired] do
    {:error, "Cannot log distance for vehicle with status: #{status}"}
  end

  def log_distance(%__MODULE__{} = vehicle, km) when is_integer(km) and km > 0 do
    {:ok, %{vehicle | odometer_km: vehicle.odometer_km + km}}
  end

  def log_distance(_, _), do: {:error, "Distance must be a positive integer"}

  @spec change_status(t(), status()) :: {:ok, t()} | {:error, String.t()}
  def change_status(%__MODULE__{status: :retired}, _new_status) do
    {:error, "Retired vehicles cannot change status"}
  end

  def change_status(%__MODULE__{} = vehicle, new_status)
      when new_status in [:available, :in_service, :maintenance, :retired] do
    {:ok, %{vehicle | status: new_status}}
  end

  def change_status(_, status), do: {:error, "Unknown status: #{inspect(status)}"}

  @spec service_due?(t()) :: boolean()
  def service_due?(%__MODULE__{odometer_km: odo, last_service_km: last, service_interval_km: interval}) do
    odo - last >= interval
  end

  @spec record_service(t()) :: {:ok, t()} | {:error, String.t()}
  def record_service(%__MODULE__{status: :maintenance} = vehicle) do
    {:ok, %{vehicle | last_service_km: vehicle.odometer_km, status: :available}}
  end

  def record_service(%__MODULE__{status: status}) do
    {:error, "Service can only be recorded when vehicle is in maintenance, got: #{status}"}
  end

  @spec last_known_location(t()) :: {:ok, location_entry()} | {:error, :no_location_data}
  def last_known_location(%__MODULE__{location_history: [latest | _]}), do: {:ok, latest}
  def last_known_location(%__MODULE__{location_history: []}), do: {:error, :no_location_data}

  @spec validate_plate(String.t()) :: :ok | {:error, String.t()}
  defp validate_plate(plate) do
    if String.match?(plate, ~r/^[A-Za-z0-9\-]{4,10}$/) do
      :ok
    else
      {:error, "Invalid plate format: #{plate}"}
    end
  end
end
```
