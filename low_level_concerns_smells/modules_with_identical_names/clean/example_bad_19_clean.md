```elixir
# ── file: lib/iot/device.ex ───────────────────────────────────────────────────

defmodule IoT.Device do
  @moduledoc """
  Handles IoT device provisioning, certificate management, and registration
  into the device registry. Used by the manufacturing provisioning pipeline
  and self-service device onboarding API.
  """

  alias IoT.{CertificateAuthority, DeviceRegistry, FirmwareRegistry, PolicyEngine}

  @supported_protocols [:mqtt, :coap, :https]
  @default_telemetry_interval_seconds 60

  @type t :: %__MODULE__{
          id: String.t(),
          serial_number: String.t(),
          device_type: String.t(),
          firmware_version: String.t(),
          protocol: atom(),
          certificate_fingerprint: String.t() | nil,
          policy_group: String.t(),
          telemetry_interval_seconds: pos_integer(),
          last_seen_at: DateTime.t() | nil,
          status: :provisioning | :active | :inactive | :quarantine | :decommissioned,
          registered_at: DateTime.t()
        }

  defstruct [
    :id,
    :serial_number,
    :device_type,
    :firmware_version,
    :protocol,
    :certificate_fingerprint,
    :policy_group,
    :last_seen_at,
    :registered_at,
    telemetry_interval_seconds: @default_telemetry_interval_seconds,
    status: :provisioning
  ]

  @spec provision(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def provision(serial_number, attrs) do
    device_type = Map.fetch!(attrs, :device_type)
    protocol = Map.get(attrs, :protocol, :mqtt)

    with :ok <- validate_protocol(protocol),
         :ok <- check_serial_unique(serial_number),
         {:ok, firmware} <- FirmwareRegistry.latest(device_type),
         {:ok, cert} <- CertificateAuthority.issue(serial_number),
         {:ok, policy_group} <- PolicyEngine.assign_group(device_type) do
      device = %__MODULE__{
        id: generate_id(),
        serial_number: serial_number,
        device_type: device_type,
        firmware_version: firmware.version,
        protocol: protocol,
        certificate_fingerprint: cert.fingerprint,
        policy_group: policy_group,
        telemetry_interval_seconds: Map.get(attrs, :telemetry_interval_seconds, @default_telemetry_interval_seconds),
        status: :active,
        registered_at: DateTime.utc_now()
      }

      DeviceRegistry.register(device)

      {:ok, Map.put(device, :certificate_pem, cert.pem)}
    end
  end

  @spec decommission(String.t()) :: {:ok, map()} | {:error, term()}
  def decommission(device_id) do
    with {:ok, device} <- DeviceRegistry.fetch(device_id) do
      CertificateAuthority.revoke(device.certificate_fingerprint)
      updated = DeviceRegistry.update(device_id, %{status: :decommissioned})
      {:ok, updated}
    end
  end

  @spec quarantine(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def quarantine(device_id, reason) do
    with {:ok, _device} <- DeviceRegistry.fetch(device_id) do
      updated = DeviceRegistry.update(device_id, %{status: :quarantine, quarantine_reason: reason})
      {:ok, updated}
    end
  end

  defp validate_protocol(p) when p in @supported_protocols, do: :ok
  defp validate_protocol(p), do: {:error, {:unsupported_protocol, p}}

  defp check_serial_unique(serial) do
    case DeviceRegistry.find_by_serial(serial) do
      nil -> :ok
      _ -> {:error, :serial_already_registered}
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
end


# ── file: lib/iot/device_telemetry.ex ────────────────────────────────────────

defmodule IoT.Device do
  @moduledoc """
  Handles inbound telemetry data from registered IoT devices.
  Validates, normalises, and routes sensor payloads to the time-series store.
  """

  alias IoT.{DeviceRegistry, TimeSeriesStore, AlertEngine, PolicyEngine}

  @max_payload_bytes 65_536

  @type telemetry_reading :: %{
          device_id: String.t(),
          metric: String.t(),
          value: number(),
          unit: String.t(),
          timestamp: DateTime.t()
        }

  @spec ingest_telemetry(String.t(), map()) :: {:ok, [telemetry_reading()]} | {:error, term()}
  def ingest_telemetry(device_id, payload) do
    with {:ok, device} <- DeviceRegistry.fetch(device_id),
         :ok <- validate_device_active(device),
         :ok <- validate_payload_size(payload) do
      readings = normalise_payload(device, payload)

      TimeSeriesStore.batch_insert(readings)
      DeviceRegistry.update(device_id, %{last_seen_at: DateTime.utc_now()})

      anomalies = AlertEngine.evaluate(device, readings)
      Enum.each(anomalies, &AlertEngine.fire/1)

      {:ok, readings}
    end
  end

  @spec get_latest(String.t(), String.t()) :: {:ok, telemetry_reading()} | {:error, :not_found}
  def get_latest(device_id, metric) do
    TimeSeriesStore.latest(device_id, metric)
  end

  @spec get_history(String.t(), String.t(), DateTime.t(), DateTime.t()) :: {:ok, [telemetry_reading()]}
  def get_history(device_id, metric, from, to) do
    TimeSeriesStore.range(device_id, metric, from, to)
  end

  @spec configure_interval(String.t(), pos_integer()) :: :ok | {:error, term()}
  def configure_interval(device_id, interval_seconds) do
    with {:ok, device} <- DeviceRegistry.fetch(device_id) do
      policy = PolicyEngine.get_group_policy(device.policy_group)

      if interval_seconds >= policy.min_telemetry_interval do
        DeviceRegistry.update(device_id, %{telemetry_interval_seconds: interval_seconds})
        :ok
      else
        {:error, :interval_below_policy_minimum}
      end
    end
  end

  defp validate_device_active(%{status: :active}), do: :ok
  defp validate_device_active(%{status: status}), do: {:error, {:device_not_active, status}}

  defp validate_payload_size(payload) do
    encoded = :erlang.term_to_binary(payload)
    if byte_size(encoded) <= @max_payload_bytes, do: :ok, else: {:error, :payload_too_large}
  end

  defp normalise_payload(device, %{readings: readings}) when is_list(readings) do
    Enum.map(readings, fn r ->
      %{
        device_id: device.id,
        metric: r["metric"],
        value: r["value"],
        unit: r["unit"] || "unknown",
        timestamp: parse_timestamp(r["timestamp"])
      }
    end)
  end

  defp normalise_payload(device, payload) do
    [
      %{
        device_id: device.id,
        metric: payload["metric"],
        value: payload["value"],
        unit: payload["unit"] || "unknown",
        timestamp: parse_timestamp(payload["timestamp"])
      }
    ]
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts), do: DateTime.from_iso8601(ts) |> elem(1)
  defp parse_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
end
```
