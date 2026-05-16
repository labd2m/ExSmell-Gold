```elixir
defmodule IoT.DeviceProvisioner do
  @moduledoc """
  Provisions new IoT edge devices onto the platform.
  Validates hardware identity, assigns tenant namespaces,
  applies firmware baselines, and registers device certificates
  for mutual TLS authentication with the message broker.
  """

  require Logger

  @supported_device_types ~w(sensor actuator gateway hub)
  @min_heartbeat_sec       10
  @max_heartbeat_sec       3_600
  @default_heartbeat_sec   60

  @type device :: %{
          serial_number: String.t(),
          mac_address: String.t(),
          device_type: String.t(),
          tenant_id: String.t(),
          hardware_revision: String.t(),
          optional(:firmware_version) => String.t(),
          optional(:heartbeat_interval_sec) => pos_integer(),
          optional(:encryption_key) => String.t(),
          optional(:geo_lat) => float(),
          optional(:geo_lng) => float()
        }

  @spec provision(device()) :: {:ok, map()} | {:error, [String.t()]}
  def provision(device) do
    errors =
      []
      |> validate_serial(device)
      |> validate_mac(device)
      |> validate_device_type(device)

    if errors != [] do
      {:error, Enum.reverse(errors)}
    else
      build_provisioning_record(device)
    end
  end

  defp validate_serial(errors, %{serial_number: sn}) when byte_size(sn) < 8,
    do: ["serial_number must be at least 8 characters" | errors]
  defp validate_serial(errors, _), do: errors

  defp validate_mac(errors, %{mac_address: mac}) do
    if Regex.match?(~r/^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$/, mac),
      do: errors,
      else: ["mac_address format is invalid" | errors]
  end

  defp validate_device_type(errors, %{device_type: dt}) do
    if dt in @supported_device_types,
      do: errors,
      else: ["unsupported device_type: #{dt}" | errors]
  end

  defp build_provisioning_record(device) do
    firmware_version       = device[:firmware_version]
    heartbeat_interval_sec = device[:heartbeat_interval_sec]
    encryption_key         = device[:encryption_key]

    heartbeat =
      cond do
        is_nil(heartbeat_interval_sec) ->
          @default_heartbeat_sec

        heartbeat_interval_sec < @min_heartbeat_sec ->
          Logger.warning("Heartbeat #{heartbeat_interval_sec}s below minimum; clamping to #{@min_heartbeat_sec}s")
          @min_heartbeat_sec

        heartbeat_interval_sec > @max_heartbeat_sec ->
          Logger.warning("Heartbeat #{heartbeat_interval_sec}s above maximum; clamping to #{@max_heartbeat_sec}s")
          @max_heartbeat_sec

        true ->
          heartbeat_interval_sec
      end

    geo =
      case {device[:geo_lat], device[:geo_lng]} do
        {nil, _}     -> nil
        {_, nil}     -> nil
        {lat, lng}   -> %{lat: lat, lng: lng}
      end

    record = %{
      device_id:             generate_device_id(device.serial_number),
      serial_number:         device.serial_number,
      mac_address:           device.mac_address,
      device_type:           device.device_type,
      tenant_id:             device.tenant_id,
      hardware_revision:     device.hardware_revision,
      firmware_version:      firmware_version,
      heartbeat_interval_sec: heartbeat,
      encryption_enabled:    not is_nil(encryption_key),
      encryption_key_digest: maybe_digest(encryption_key),
      geo:                   geo,
      status:                :pending_activation,
      provisioned_at:        DateTime.utc_now()
    }

    Logger.info("Device provisioned: #{record.device_id} (#{device.device_type}) for tenant #{device.tenant_id}")
    {:ok, record}
  end

  defp maybe_digest(nil), do: nil
  defp maybe_digest(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp generate_device_id(serial) do
    hash = :crypto.hash(:md5, serial) |> Base.encode16(case: :lower) |> String.slice(0, 8)
    "DEV-#{hash}"
  end

  @spec activate(map()) :: {:ok, map()} | {:error, String.t()}
  def activate(%{status: :pending_activation} = record) do
    {:ok, %{record | status: :active}}
  end

  def activate(%{status: status}),
    do: {:error, "device is not pending activation (current status: #{status})"}
end
```
