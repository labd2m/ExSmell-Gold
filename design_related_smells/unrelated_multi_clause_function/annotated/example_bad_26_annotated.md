# Annotated Example 26

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `DeviceManager.apply_command/1`
- **Affected function(s):** `apply_command/1`
- **Short explanation:** `apply_command/1` processes firmware update commands, remote device wipe commands, and sensor calibration commands — three unrelated IoT device management operations — under a single multi-clause function. Each clause communicates with different device subsystems and has distinct safety and rollback requirements.

```elixir
defmodule DeviceManager do
  @moduledoc """
  IoT device management module for the fleet operations platform.
  Issues and tracks firmware updates, remote wipe commands, and
  sensor calibration procedures across registered devices.
  """

  alias DeviceManager.{
    FirmwareUpdateCommand,
    RemoteWipeCommand,
    CalibrationCommand,
    DeviceRegistry,
    FirmwareStore,
    CommandDispatcher,
    CommandLog,
    FleetNotifier,
    RollbackManager
  }

  require Logger

  @doc """
  Apply a remote command to a registered IoT device.

  Accepts a `%FirmwareUpdateCommand{}`, `%RemoteWipeCommand{}`, or
  `%CalibrationCommand{}` and dispatches it to the target device.

  ## Examples

      iex> DeviceManager.apply_command(%FirmwareUpdateCommand{device_id: "dev_001", version: "2.4.1"})
      {:ok, %{command_id: "cmd_xyz", status: :dispatched}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because issuing a firmware OTA update,
  # remotely wiping a device, and running a sensor calibration sequence
  # are completely different device management operations with different
  # safety implications, rollback strategies, and authorization levels.
  # Grouping them under `apply_command/1` mixes unrelated IoT operations.

  def apply_command(%FirmwareUpdateCommand{
        device_id: device_id,
        version: target_version,
        rollback_on_failure: rollback,
        scheduled_at: scheduled_at
      }) do
    with {:ok, device} <- DeviceRegistry.find(device_id),
         :ok <- validate_device_online(device),
         {:ok, firmware} <- FirmwareStore.find_version(target_version, device.model),
         :ok <- validate_firmware_compatible(firmware, device),
         {:ok, command} <-
           CommandDispatcher.dispatch(device_id, :firmware_update, %{
             firmware_url: firmware.download_url,
             checksum: firmware.sha256,
             version: target_version,
             scheduled_at: scheduled_at
           }),
         :ok <-
           CommandLog.record(%{
             device_id: device_id,
             command_id: command.id,
             type: :firmware_update,
             payload: %{version: target_version},
             dispatched_at: DateTime.utc_now()
           }),
         :ok <- maybe_schedule_rollback(rollback, device_id, command.id, device.firmware_version) do
      Logger.info("Firmware update #{target_version} dispatched to device #{device_id}")
      {:ok, %{command_id: command.id, status: :dispatched}}
    end
  end

  # apply remote wipe command for lost or decommissioned device
  def apply_command(%RemoteWipeCommand{
        device_id: device_id,
        authorized_by: authorized_by,
        wipe_level: wipe_level,
        reason: reason
      })
      when wipe_level in [:soft, :hard, :cryptographic] do
    with {:ok, device} <- DeviceRegistry.find(device_id),
         :ok <- validate_wipe_authorization(authorized_by, wipe_level),
         {:ok, command} <-
           CommandDispatcher.dispatch(device_id, :remote_wipe, %{
             level: wipe_level,
             confirm_token: generate_wipe_token(device_id, authorized_by)
           }),
         :ok <-
           CommandLog.record(%{
             device_id: device_id,
             command_id: command.id,
             type: :remote_wipe,
             payload: %{level: wipe_level, reason: reason, authorized_by: authorized_by},
             dispatched_at: DateTime.utc_now()
           }),
         {:ok, _} <-
           DeviceRegistry.update(device_id, %{status: :wipe_pending, decommissioned_at: DateTime.utc_now()}),
         :ok <- FleetNotifier.broadcast_wipe_initiated(device_id, authorized_by) do
      Logger.warning("Remote wipe (#{wipe_level}) dispatched to device #{device_id} by #{authorized_by}")
      {:ok, %{command_id: command.id, status: :dispatched}}
    end
  end

  # apply sensor calibration command to adjust device readings
  def apply_command(%CalibrationCommand{
        device_id: device_id,
        sensor_type: sensor_type,
        reference_values: reference_values,
        operator_id: operator_id
      }) do
    with {:ok, device} <- DeviceRegistry.find(device_id),
         :ok <- validate_device_online(device),
         :ok <- validate_sensor_present(device, sensor_type),
         {:ok, cal_profile} <- build_calibration_profile(sensor_type, reference_values),
         {:ok, command} <-
           CommandDispatcher.dispatch(device_id, :calibrate, %{
             sensor: sensor_type,
             profile: cal_profile
           }),
         :ok <-
           CommandLog.record(%{
             device_id: device_id,
             command_id: command.id,
             type: :calibration,
             payload: %{sensor_type: sensor_type, operator_id: operator_id},
             dispatched_at: DateTime.utc_now()
           }) do
      Logger.info("Calibration command sent to device #{device_id} for sensor #{sensor_type}")
      {:ok, %{command_id: command.id, status: :dispatched}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_device_online(%{connectivity_status: :online}), do: :ok
  defp validate_device_online(_), do: {:error, :device_offline}

  defp validate_firmware_compatible(firmware, device) do
    if firmware.supported_models |> Enum.member?(device.model) do
      :ok
    else
      {:error, :firmware_incompatible_with_model}
    end
  end

  defp validate_wipe_authorization(_authorized_by, :soft), do: :ok
  defp validate_wipe_authorization(authorized_by, _level) do
    case DeviceRegistry.check_admin_role(authorized_by) do
      true -> :ok
      false -> {:error, :insufficient_authorization}
    end
  end

  defp validate_sensor_present(device, sensor_type) do
    if sensor_type in device.sensor_types do
      :ok
    else
      {:error, {:sensor_not_present, sensor_type}}
    end
  end

  defp generate_wipe_token(device_id, authorized_by) do
    :crypto.hash(:sha256, "#{device_id}:#{authorized_by}:#{System.os_time()}")
    |> Base.encode16(case: :lower)
  end

  defp build_calibration_profile(sensor_type, reference_values) do
    offsets = Enum.map(reference_values, fn {point, ref} -> {point, ref} end) |> Map.new()
    {:ok, %{sensor_type: sensor_type, offsets: offsets, calibrated_at: DateTime.utc_now()}}
  end

  defp maybe_schedule_rollback(true, device_id, command_id, previous_version) do
    RollbackManager.schedule(device_id, command_id, previous_version, timeout_minutes: 30)
  end

  defp maybe_schedule_rollback(false, _device_id, _command_id, _prev), do: :ok
end
```
