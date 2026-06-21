```elixir
defmodule MyApp.IoT.CommandAcknowledger do
  @moduledoc """
  Listens for device acknowledgement messages arriving on a dedicated
  MQTT topic and correlates them with outstanding command records stored
  in the `device_commands` table. Acknowledged commands are marked as
  complete; commands that remain unacknowledged past their expiry are
  swept by a separate reconciliation job.

  This module is a plain GenServer that subscribes to the MQTT connection
  managed by `Tortoise311`; no additional supervision is required beyond
  starting this process.
  """

  use GenServer

  require Logger

  alias MyApp.Devices.CommandDispatcher

  @ack_topic_prefix "devices/+/acks"
  @mqtt_client MyApp.MQTTClient

  @doc "Starts the acknowledger."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    Tortoise311.subscribe(@mqtt_client, {@ack_topic_prefix, 1})
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({Tortoise311, :receive, topic, payload}, state) do
    case parse_ack(topic, payload) do
      {:ok, command_id} ->
        handle_ack(command_id)

      {:error, reason} ->
        Logger.warning("device_ack_parse_failed",
          topic: topic,
          reason: inspect(reason)
        )
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @spec parse_ack(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  defp parse_ack(_topic, payload) do
    case Jason.decode(payload) do
      {:ok, %{"command_id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, _} -> {:error, :missing_command_id}
      {:error, reason} -> {:error, {:json_decode_failed, reason}}
    end
  end

  @spec handle_ack(String.t()) :: :ok
  defp handle_ack(command_id) do
    case CommandDispatcher.acknowledge(command_id) do
      :ok ->
        Logger.info("device_command_acknowledged", command_id: command_id)

      {:error, :not_found} ->
        Logger.warning("device_ack_unknown_command", command_id: command_id)
    end
  end
end
```
