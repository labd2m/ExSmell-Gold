```elixir
defmodule IoT.CommandProcessor do
  @moduledoc """
  Processes inbound command messages from IoT devices connected via MQTT.
  Validates command structure, routes to the appropriate device handler,
  and persists command acknowledgements for audit purposes.
  """

  require Logger

  alias IoT.{DeviceRegistry, CommandRouter, AckStore, DevicePolicy, TelemetryPipeline}

  @ack_ttl_seconds 86_400
  @max_payload_bytes 65_536

  @spec process(String.t(), binary()) :: :ok | {:error, term()}
  def process(topic, raw_payload) do
    Logger.debug("Processing IoT command", topic: topic)

    with {:ok, device_id} <- extract_device_id(topic),
         {:ok, device} <- DeviceRegistry.lookup(device_id),
         :ok <- DevicePolicy.check_active(device),
         {:ok, message} <- decode_message(raw_payload),
         {:ok, action} <- decode_action(message["action"]),
         :ok <- DevicePolicy.check_permitted(device, action),
         {:ok, result} <- CommandRouter.dispatch(device, action, message["payload"]),
         :ok <- AckStore.record(device_id, message["message_id"], result, ttl: @ack_ttl_seconds) do
      TelemetryPipeline.emit(:command_processed, %{device_id: device_id, action: action})
      :ok
    else
      {:error, :device_not_found} ->
        Logger.warning("Command from unregistered device", topic: topic)
        {:error, :device_not_found}

      {:error, :device_inactive} ->
        Logger.warning("Command from inactive device", topic: topic)
        {:error, :device_inactive}

      {:error, :action_not_permitted} = err ->
        Logger.warning("Unpermitted action attempted", topic: topic)
        err

      {:error, reason} = err ->
        Logger.error("Command processing failed", topic: topic, reason: inspect(reason))
        err
    end
  end

  defp extract_device_id(topic) when is_binary(topic) do
    case String.split(topic, "/") do
      ["devices", device_id, "commands"] -> {:ok, device_id}
      _ -> {:error, {:invalid_topic, topic}}
    end
  end

  defp decode_message(raw) when byte_size(raw) > @max_payload_bytes do
    {:error, :payload_too_large}
  end

  defp decode_message(raw) do
    case Jason.decode(raw) do
      {:ok, %{"action" => _, "message_id" => _} = msg} -> {:ok, msg}
      {:ok, _} -> {:error, :missing_required_message_fields}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_action(nil), do: {:error, :missing_action}

  defp decode_action(action) when is_binary(action) do
    {:ok, String.to_atom(action)}
  end

  defp decode_action(_), do: {:error, :invalid_action_type}
end
```
