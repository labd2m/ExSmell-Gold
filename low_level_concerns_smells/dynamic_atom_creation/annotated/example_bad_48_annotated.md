# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `decode_action/1` function
- **Affected function(s):** `decode_action/1`
- **Short explanation:** The function converts an action name string from an incoming IoT device command message into an atom using `String.to_atom/1`. IoT devices are manufactured by many vendors with varying firmware, and the set of action strings any given device may send is not controlled by the application developer, making this an externally driven and unbounded source of atoms.

---

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

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to the
  # action string extracted from a device command message received over MQTT.
  # IoT devices from different manufacturers and firmware versions can send
  # arbitrary action strings. The developer has no compile-time control over
  # what action values devices will produce, especially as new device models or
  # firmware updates are deployed to the field. Each unique action string
  # creates a new permanent atom.
  defp decode_action(nil), do: {:error, :missing_action}

  defp decode_action(action) when is_binary(action) do
    {:ok, String.to_atom(action)}
  end
  # VALIDATION: SMELL END

  defp decode_action(_), do: {:error, :invalid_action_type}
end
```
