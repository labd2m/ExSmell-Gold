```elixir
defmodule MyApp.IoT.IoTMessageHandler do
  @moduledoc """
  Processes inbound MQTT messages from IoT field devices.
  Decodes topic structure, validates payloads, and routes sensor
  readings to the appropriate time-series storage and alerting pipeline.
  """

  require Logger

  alias MyApp.IoT.{DeviceRegistry, SensorStore, AlertEngine, PayloadDecoder}

  @qos_levels [0, 1, 2]
  @max_payload_bytes 65_536

  @doc """
  Entry point called by the MQTT broker adapter for every inbound message.
  """
  @spec handle(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def handle(topic, payload, opts \\ []) when is_binary(topic) and is_binary(payload) do
    qos = Keyword.get(opts, :qos, 0)
    retained = Keyword.get(opts, :retained, false)

    Logger.debug("Received MQTT message", topic: topic, qos: qos, retained: retained)

    with :ok <- validate_payload_size(payload),
         {:ok, topic_parts} <- decode_topic(topic),
         {:ok, device} <- resolve_device(topic_parts),
         {:ok, reading} <- PayloadDecoder.decode(payload, topic_parts.sensor_type),
         :ok <- SensorStore.insert(device.id, topic_parts.sensor_type, reading),
         :ok <- AlertEngine.evaluate(device, topic_parts.sensor_type, reading) do
      Logger.debug("Message processed", device_id: device.id, sensor: topic_parts.sensor_type)
      :ok
    else
      {:error, :device_not_found} ->
        Logger.warning("Message from unknown device", topic: topic)
        :ok

      {:error, reason} = err ->
        Logger.error("Failed to process MQTT message", topic: topic, reason: inspect(reason))
        err
    end
  end

  @doc """
  Subscribes the handler to a wildcard topic pattern on the broker.
  """
  @spec subscribe_all(pid()) :: :ok
  def subscribe_all(broker_pid) do
    patterns = [
      "devices/+/sensors/+/readings",
      "devices/+/status",
      "devices/+/config/ack"
    ]

    Enum.each(patterns, fn pattern ->
      :emqtt.subscribe(broker_pid, pattern, qos: 1)
      Logger.info("Subscribed to MQTT pattern", pattern: pattern)
    end)

    :ok
  end

  defp decode_topic(topic) when is_binary(topic) do
    case String.split(topic, "/") do
      ["devices", device_id, "sensors", sensor_type, "readings"] ->
        parts = %{
          device_id: device_id,
          sensor_type: String.to_atom(sensor_type),
          message_kind: :reading
        }

        {:ok, parts}

      ["devices", device_id, "status"] ->
        {:ok, %{device_id: device_id, sensor_type: :none, message_kind: :status}}

      ["devices", device_id, "config", "ack"] ->
        {:ok, %{device_id: device_id, sensor_type: :none, message_kind: :config_ack}}

      _ ->
        {:error, {:unrecognised_topic, topic}}
    end
  end

  defp resolve_device(%{device_id: device_id}) do
    DeviceRegistry.lookup(device_id)
  end

  defp validate_payload_size(payload) when byte_size(payload) > @max_payload_bytes do
    {:error, {:payload_too_large, byte_size(payload)}}
  end

  defp validate_payload_size(_), do: :ok
end
```
