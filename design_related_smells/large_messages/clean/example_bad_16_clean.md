```elixir
defmodule IoT.SensorMetadata do
  defstruct [
    :device_id,
    :firmware_version,
    :hardware_revision,
    :installation_site,
    :calibration_date,
    :communication_protocol
  ]
end

defmodule IoT.Reading do
  @enforce_keys [:reading_id, :device_id, :metric, :value, :unit, :timestamp]
  defstruct [
    :reading_id,
    :device_id,
    :metric,
    :value,
    :unit,
    :timestamp,
    :quality,
    :raw_bytes,
    :metadata
  ]
end

defmodule IoT.DeviceReports do
  @moduledoc "Simulates accumulating a window of sensor readings from many devices."

  @spec collect_window(non_neg_integer(), non_neg_integer()) :: list(IoT.Reading.t())
  def collect_window(device_count, readings_per_device) do
    for device_i <- 1..device_count,
        reading_j <- 1..readings_per_device do
      metric = Enum.random(["temperature", "humidity", "pressure", "co2_ppm", "vibration_hz"])
      value = :rand.uniform() * 100

      %IoT.Reading{
        reading_id: "READ-#{device_i}-#{reading_j}-#{:erlang.unique_integer([:positive])}",
        device_id: "DEV-#{device_i}",
        metric: metric,
        value: Float.round(value, 4),
        unit: %{"temperature" => "°C", "humidity" => "%", "pressure" => "hPa",
                 "co2_ppm" => "ppm", "vibration_hz" => "Hz"}[metric],
        timestamp: System.system_time(:millisecond) - reading_j * 1_000,
        quality: if(:rand.uniform() > 0.02, do: :good, else: :degraded),
        raw_bytes: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
        metadata: %IoT.SensorMetadata{
          device_id: "DEV-#{device_i}",
          firmware_version: "3.#{rem(device_i, 10)}.#{rem(reading_j, 20)}",
          hardware_revision: "rev-B",
          installation_site: "site-#{rem(device_i, 50)}",
          calibration_date: Date.utc_today() |> Date.add(-rem(device_i * 7, 365)),
          communication_protocol: Enum.random(["MQTT", "CoAP", "HTTP"])
        }
      }
    end
  end
end

defmodule IoT.DataAggregator do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{windows_received: 0, total_readings: 0}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:readings_window, gateway_id, readings}, state) do
    by_device =
      Enum.group_by(readings, & &1.device_id)

    _summaries =
      Enum.map(by_device, fn {device_id, device_readings} ->
        avg = Enum.sum(Enum.map(device_readings, & &1.value)) / length(device_readings)
        {device_id, Float.round(avg, 2)}
      end)

    _ = gateway_id

    {:noreply,
     %{
       state
       | windows_received: state.windows_received + 1,
         total_readings: state.total_readings + length(readings)
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end
end

defmodule IoT.GatewayForwarder do
  @moduledoc """
  Gateway process that collects sensor readings for a time window and
  forwards them to the central data aggregator for processing.
  """

  require Logger

  @devices_per_gateway 500
  @readings_per_device 20

  @spec forward_readings(pid(), String.t()) :: :ok
  def forward_readings(aggregator_pid, gateway_id) do
    Logger.info(
      "Collecting window for gateway #{gateway_id} — " <>
        "#{@devices_per_gateway} devices × #{@readings_per_device} readings"
    )

    readings = IoT.DeviceReports.collect_window(@devices_per_gateway, @readings_per_device)

    Logger.info(
      "Collection complete — #{length(readings)} readings total — forwarding to aggregator"
    )

    send(aggregator_pid, {:readings_window, gateway_id, readings})

    :ok
  end

  @spec start_collection_loop(pid(), String.t(), non_neg_integer()) :: :ok
  def start_collection_loop(aggregator_pid, gateway_id, interval_ms \\ 5_000) do
    Stream.interval(interval_ms)
    |> Stream.each(fn _ -> forward_readings(aggregator_pid, gateway_id) end)
    |> Stream.run()
  end
end
```
