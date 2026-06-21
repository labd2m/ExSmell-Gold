```elixir
defmodule MyApp.Devices.CommandDispatcher do
  @moduledoc """
  Dispatches control commands to IoT field devices over MQTT. Each command
  is serialised to JSON, published to the device-specific topic, and tracked
  in the `device_commands` table so that acknowledgment timeouts can be
  detected by a separate reconciliation job.

  The dispatcher itself is stateless; MQTT connection management is handled
  by a separately supervised `Tortoise311` connection named `MyApp.MQTTClient`.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Devices.{Command, Device}

  @command_topic_prefix "devices"
  @ack_timeout_seconds 30

  @type device_id :: String.t()
  @type command_type :: :reboot | :sync_config | :firmware_update | :diagnostics
  @type command_payload :: map()

  @doc """
  Sends a typed command to a device and persists a tracking record.
  Returns `{:ok, command_id}` when the MQTT publish succeeds, or a
  structured error tuple on validation or transport failure.
  """
  @spec dispatch(Device.t(), command_type(), command_payload()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch(%Device{} = device, command_type, payload \\ %{})
      when command_type in [:reboot, :sync_config, :firmware_update, :diagnostics] do
    command_id = generate_id()

    with :ok <- validate_device_online(device),
         {:ok, _record} <- persist_command(command_id, device, command_type, payload),
         :ok <- publish_command(device.id, command_id, command_type, payload) do
      Logger.info("device_command_dispatched",
        device_id: device.id,
        command_id: command_id,
        command_type: command_type
      )

      {:ok, command_id}
    end
  end

  @doc """
  Marks a command as acknowledged. Called when the device publishes
  to its acknowledgment topic.
  """
  @spec acknowledge(String.t()) :: :ok | {:error, :not_found}
  def acknowledge(command_id) when is_binary(command_id) do
    case Repo.get_by(Command, command_id: command_id, status: :pending) do
      nil ->
        {:error, :not_found}

      command ->
        command
        |> Command.ack_changeset()
        |> Repo.update()

        :ok
    end
  end

  @spec validate_device_online(Device.t()) :: :ok | {:error, :device_offline}
  defp validate_device_online(%Device{online: true}), do: :ok
  defp validate_device_online(_), do: {:error, :device_offline}

  @spec persist_command(String.t(), Device.t(), command_type(), command_payload()) ::
          {:ok, Command.t()} | {:error, Ecto.Changeset.t()}
  defp persist_command(command_id, device, command_type, payload) do
    expires_at = DateTime.add(DateTime.utc_now(), @ack_timeout_seconds, :second)

    %Command{}
    |> Command.changeset(%{
      command_id: command_id,
      device_id: device.id,
      command_type: command_type,
      payload: payload,
      status: :pending,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  @spec publish_command(device_id(), String.t(), command_type(), command_payload()) ::
          :ok | {:error, term()}
  defp publish_command(device_id, command_id, command_type, payload) do
    topic = "#{@command_topic_prefix}/#{device_id}/commands"

    message =
      Jason.encode!(%{
        command_id: command_id,
        type: command_type,
        payload: payload,
        issued_at: DateTime.utc_now()
      })

    Tortoise311.publish(MyApp.MQTTClient, topic, message, qos: 1)
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
```
