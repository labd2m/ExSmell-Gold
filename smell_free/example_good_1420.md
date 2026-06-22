```elixir
defmodule Devices.Firmware.UpdateOrchestrator do
  @moduledoc """
  Orchestrates over-the-air firmware updates for registered device fleets.
  Updates are rolled out in configurable batch sizes with health checks
  between batches. A failed batch halts the rollout and reports affected devices.
  """

  alias Devices.Firmware.{UpdateManifest, DeviceRegistry, UpdateClient}

  @type device_id :: String.t()
  @type batch_result :: %{
          succeeded: [device_id()],
          failed: [device_id()],
          errors: %{device_id() => String.t()}
        }
  @type rollout_result :: %{
          manifest_id: String.t(),
          total_devices: non_neg_integer(),
          batches_completed: non_neg_integer(),
          succeeded: [device_id()],
          failed: [device_id()],
          halted: boolean()
        }

  @doc """
  Rolls out `manifest` to all eligible devices in `batch_size` groups.
  Returns a full rollout result including per-device outcomes.

  ## Options
    - `:batch_size` - devices per batch (default: 10)
    - `:registry` - device registry module (default: DeviceRegistry)
    - `:client` - update client module (default: UpdateClient)
    - `:halt_on_failure_rate` - float 0.0–1.0; halts if exceeded in any batch (default: 0.5)
  """
  @spec rollout(UpdateManifest.t(), keyword()) ::
          {:ok, rollout_result()} | {:error, String.t()}
  def rollout(%UpdateManifest{} = manifest, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 10)
    registry = Keyword.get(opts, :registry, DeviceRegistry)
    client = Keyword.get(opts, :client, UpdateClient)
    halt_threshold = Keyword.get(opts, :halt_on_failure_rate, 0.5)

    with :ok <- validate_manifest(manifest),
         :ok <- validate_batch_size(batch_size),
         {:ok, devices} <- registry.eligible_devices(manifest.target_firmware_version) do
      execute_rollout(manifest, devices, batch_size, halt_threshold, client)
    end
  end

  defp execute_rollout(manifest, devices, batch_size, halt_threshold, client) do
    batches = Enum.chunk_every(devices, batch_size)
    total = length(devices)

    initial_acc = %{
      succeeded: [],
      failed: [],
      batches_completed: 0,
      halted: false
    }

    final =
      Enum.reduce_while(batches, initial_acc, fn batch, acc ->
        result = deliver_batch(batch, manifest, client)
        updated = merge_batch_result(acc, result)

        if should_halt?(result, halt_threshold) do
          {:halt, %{updated | halted: true}}
        else
          {:cont, %{updated | batches_completed: updated.batches_completed + 1}}
        end
      end)

    {:ok,
     %{
       manifest_id: manifest.id,
       total_devices: total,
       batches_completed: final.batches_completed,
       succeeded: final.succeeded,
       failed: final.failed,
       halted: final.halted
     }}
  end

  defp deliver_batch(device_ids, manifest, client) do
    device_ids
    |> Task.async_stream(
      fn device_id -> {device_id, client.push(device_id, manifest)} end,
      ordered: false,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{succeeded: [], failed: [], errors: %{}}, fn result, acc ->
      case result do
        {:ok, {device_id, :ok}} ->
          %{acc | succeeded: [device_id | acc.succeeded]}

        {:ok, {device_id, {:error, reason}}} ->
          %{acc | failed: [device_id | acc.failed], errors: Map.put(acc.errors, device_id, reason)}

        {:exit, _reason} ->
          acc
      end
    end)
  end

  defp merge_batch_result(acc, batch_result) do
    %{
      acc
      | succeeded: acc.succeeded ++ batch_result.succeeded,
        failed: acc.failed ++ batch_result.failed
    }
  end

  defp should_halt?(%{succeeded: s, failed: f}, threshold) do
    total = length(s) + length(f)

    if total == 0 do
      false
    else
      length(f) / total > threshold
    end
  end

  defp validate_manifest(%UpdateManifest{id: id, target_firmware_version: ver})
       when is_binary(id) and id != "" and is_binary(ver) and ver != "",
       do: :ok

  defp validate_manifest(_), do: {:error, "manifest must have a non-empty id and target_firmware_version"}

  defp validate_batch_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_batch_size(_), do: {:error, "batch_size must be a positive integer"}
end
```
