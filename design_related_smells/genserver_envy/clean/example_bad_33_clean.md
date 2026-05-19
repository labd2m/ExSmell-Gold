```elixir
defmodule MyApp.DeviceRegistryAgent do
  @moduledoc """
  Registry for IoT devices — manages provisioning, command dispatch,
  telemetry ingestion, and decommissioning workflows.
  """

  use Agent

  alias MyApp.{CertAuthority, MQTTBroker, FirmwareService, AuditLog, Repo}
  alias MyApp.IoT.{Device, DeviceCommand, TelemetryRecord}

  @command_timeout_seconds 30

  def start_link(_opts) do
    devices = Repo.all(Device) |> Enum.into(%{}, &{&1.device_id, &1})
    Agent.start_link(fn -> %{devices: devices, telemetry: %{}, pending_commands: %{}} end,
      name: __MODULE__)
  end

  def get_device(device_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.devices, device_id) end)
  end

  def list_online do
    Agent.get(__MODULE__, fn state ->
      state.devices |> Map.values() |> Enum.filter(&(&1.status == :online))
    end)
  end

  def provision_device(device_id, model, owner_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.devices, device_id) do
        {{:error, :already_registered}, state}
      else
        with {:ok, cert} <- CertAuthority.issue(device_id),
             {:ok, target_firmware} <- FirmwareService.latest_for_model(model),
             :ok <- MQTTBroker.register_device(device_id, cert.fingerprint) do
          device = %Device{
            device_id: device_id,
            model: model,
            owner_id: owner_id,
            cert_fingerprint: cert.fingerprint,
            cert_expires_at: cert.expires_at,
            firmware_version: nil,
            target_firmware: target_firmware,
            status: :provisioned,
            provisioned_at: DateTime.utc_now()
          }

          Repo.insert!(device)
          AuditLog.record(:device_provisioned, %{device_id: device_id, owner: owner_id})
          new_state = put_in(state, [:devices, device_id], device)
          {{:ok, device}, new_state}
        else
          {:error, reason} -> {{:error, {:provisioning_failed, reason}}, state}
        end
      end
    end)
  end

  def send_command(device_id, command_type, payload) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.devices, device_id) do
        :error ->
          {{:error, :device_not_found}, state}

        {:ok, %Device{status: :decommissioned}} ->
          {{:error, :device_decommissioned}, state}

        {:ok, device} ->
          command = %DeviceCommand{
            id: Ecto.UUID.generate(),
            device_id: device_id,
            type: command_type,
            payload: payload,
            issued_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), @command_timeout_seconds, :second),
            status: :pending
          }

          case MQTTBroker.publish(device_id, command) do
            :ok ->
              Repo.insert!(command)
              AuditLog.record(:command_sent, %{device_id: device_id, type: command_type})

              new_pending =
                Map.update(state.pending_commands, device_id, [command], &[command | &1])

              {{:ok, command}, %{state | pending_commands: new_pending}}

            {:error, reason} ->
              {{:error, {:publish_failed, reason}}, state}
          end
      end
    end)
  end

  def ingest_telemetry(device_id, readings) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.devices, device_id) do
        :error ->
          {{:error, :device_not_found}, state}

        {:ok, device} ->
          record = %TelemetryRecord{
            device_id: device_id,
            readings: readings,
            received_at: DateTime.utc_now()
          }

          updated_device = %{device | last_seen_at: DateTime.utc_now(), status: :online}
          Repo.upsert(updated_device)

          new_telemetry =
            Map.update(state.telemetry, device_id, [record], &[record | Enum.take(&1, 99)])

          new_state = %{
            state
            | devices: Map.put(state.devices, device_id, updated_device),
              telemetry: new_telemetry
          }

          {{:ok, record}, new_state}
      end
    end)
  end

  def decommission(device_id, reason) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.devices, device_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, device} ->
          CertAuthority.revoke(device.cert_fingerprint)
          MQTTBroker.deregister_device(device_id)
          updated = %{device | status: :decommissioned, decommissioned_at: DateTime.utc_now()}
          Repo.update!(updated)
          AuditLog.record(:device_decommissioned, %{device_id: device_id, reason: reason})
          {{:ok, :decommissioned}, put_in(state, [:devices, device_id], updated)}
      end
    end)
  end

end
```
