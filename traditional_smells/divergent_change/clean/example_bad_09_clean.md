```elixir
defmodule IoT.DeviceManager do
  @moduledoc """
  Handles device registration, telemetry ingestion, and firmware update management.
  """

  alias IoT.Repo
  alias IoT.Devices.Device
  alias IoT.Telemetry.Reading
  alias IoT.Firmware.UpdateJob

  import Ecto.Query
  require Logger



  @doc "Registers a new IoT device under a tenant account."
  @spec register_device(String.t(), map()) :: {:ok, Device.t()} | {:error, term()}
  def register_device(tenant_id, attrs) do
    device_attrs = %{
      tenant_id: tenant_id,
      serial_number: attrs[:serial_number],
      model: attrs[:model],
      hardware_version: attrs[:hardware_version],
      firmware_version: attrs[:firmware_version],
      status: :active,
      registered_at: DateTime.utc_now()
    }

    %Device{}
    |> Device.changeset(device_attrs)
    |> Repo.insert()
  end

  @doc "Decommissions a device, marking it as retired in the registry."
  @spec decommission_device(Device.t()) :: {:ok, Device.t()} | {:error, term()}
  def decommission_device(%Device{} = device) do
    device
    |> Device.changeset(%{status: :decommissioned, decommissioned_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Updates arbitrary metadata fields on a device (e.g. location, tags)."
  @spec update_metadata(Device.t(), map()) :: {:ok, Device.t()} | {:error, term()}
  def update_metadata(%Device{} = device, meta_attrs) do
    allowed = Map.take(meta_attrs, [:location, :tags, :description, :custom_fields])

    device
    |> Device.changeset(allowed)
    |> Repo.update()
  end


  @doc "Ingests a batch of sensor readings from a device."
  @spec ingest_telemetry(Device.t(), [map()]) :: {:ok, [Reading.t()]} | {:error, term()}
  def ingest_telemetry(%Device{id: device_id, status: :active}, readings) do
    timestamped =
      Enum.map(readings, fn r ->
        %{
          device_id: device_id,
          metric: r[:metric],
          value: r[:value],
          unit: r[:unit],
          recorded_at: r[:recorded_at] || DateTime.utc_now(),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    {count, records} = Repo.insert_all(Reading, timestamped, returning: true)
    Logger.debug("Ingested #{count} readings for device #{device_id}")
    {:ok, records}
  end

  def ingest_telemetry(%Device{status: status}, _), do: {:error, {:device_not_active, status}}

  @doc "Returns the most recent reading for each metric on a device."
  @spec get_latest_reading(Device.t()) :: [map()]
  def get_latest_reading(%Device{id: device_id}) do
    Reading
    |> where([r], r.device_id == ^device_id)
    |> distinct([r], r.metric)
    |> order_by([r], [desc: r.recorded_at])
    |> select([r], %{metric: r.metric, value: r.value, unit: r.unit, at: r.recorded_at})
    |> Repo.all()
  end

  @doc "Aggregates a specific metric over a time window using the given aggregation."
  @spec aggregate_telemetry(Device.t(), map()) :: map()
  def aggregate_telemetry(%Device{id: device_id}, %{
        metric: metric,
        from: from,
        to: to,
        agg: agg
      }) do
    query =
      Reading
      |> where(
        [r],
        r.device_id == ^device_id and r.metric == ^metric and r.recorded_at >= ^from and
          r.recorded_at <= ^to
      )

    result =
      case agg do
        :avg -> query |> select([r], avg(r.value)) |> Repo.one()
        :sum -> query |> select([r], sum(r.value)) |> Repo.one()
        :max -> query |> select([r], max(r.value)) |> Repo.one()
        :min -> query |> select([r], min(r.value)) |> Repo.one()
        :count -> query |> select([r], count(r.id)) |> Repo.one()
      end

    %{metric: metric, aggregation: agg, value: result, from: from, to: to}
  end


  @doc "Queues a firmware update job for a device."
  @spec push_firmware_update(Device.t(), String.t()) ::
          {:ok, UpdateJob.t()} | {:error, term()}
  def push_firmware_update(%Device{id: device_id, firmware_version: current}, target_version)
      when target_version != current do
    attrs = %{
      device_id: device_id,
      from_version: current,
      to_version: target_version,
      status: :pending,
      queued_at: DateTime.utc_now()
    }

    %UpdateJob{}
    |> UpdateJob.changeset(attrs)
    |> Repo.insert()
  end

  def push_firmware_update(%Device{firmware_version: v}, v), do: {:error, :already_on_version}

  @doc "Acknowledges that a device has successfully applied a firmware update."
  @spec acknowledge_update(UpdateJob.t(), String.t()) ::
          {:ok, {UpdateJob.t(), Device.t()}} | {:error, term()}
  def acknowledge_update(%UpdateJob{device_id: device_id} = job, confirmed_version) do
    Repo.transaction(fn ->
      {:ok, updated_job} =
        job
        |> UpdateJob.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
        |> Repo.update()

      device = Repo.get!(Device, device_id)

      {:ok, updated_device} =
        device
        |> Device.changeset(%{firmware_version: confirmed_version})
        |> Repo.update()

      {updated_job, updated_device}
    end)
  end

  @doc "Lists all pending firmware update jobs for a specific device."
  @spec list_pending_updates(Device.t()) :: [UpdateJob.t()]
  def list_pending_updates(%Device{id: device_id}) do
    UpdateJob
    |> where([j], j.device_id == ^device_id and j.status == :pending)
    |> order_by([j], asc: j.queued_at)
    |> Repo.all()
  end

end
```
