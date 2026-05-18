```elixir
defmodule MyApp.Logistics.ShipmentTracker do
  @moduledoc """
  Parses and processes real-time shipment status updates received from
  carrier webhooks and polling integrations.
  """

  require Logger

  alias MyApp.Logistics.{Shipment, ShipmentRepo, EventLog}
  alias MyApp.Notifications.ShipmentNotifier

  @terminal_statuses [:delivered, :returned, :lost, :cancelled]
  @actionable_statuses [:out_for_delivery, :delivery_failed, :customs_hold]

  @doc """
  Processes a raw status update map from a carrier API or webhook.
  Updates the shipment record and triggers downstream notifications.
  """
  @spec process_update(map()) :: {:ok, Shipment.t()} | {:error, term()}
  def process_update(%{"tracking_number" => tracking_number} = raw_update) do
    Logger.info("Processing shipment update", tracking_number: tracking_number)

    with {:ok, update} <- parse_status_update(raw_update),
         {:ok, shipment} <- ShipmentRepo.get_by_tracking(tracking_number),
         {:ok, updated} <- apply_update(shipment, update),
         {:ok, _} <- ShipmentRepo.save(updated),
         :ok <- EventLog.record(updated, update),
         :ok <- maybe_notify(updated) do
      {:ok, updated}
    else
      {:error, :not_found} ->
        Logger.warning("Shipment not found for update", tracking_number: tracking_number)
        {:error, :not_found}

      {:error, reason} = err ->
        Logger.error("Failed to process shipment update", reason: inspect(reason))
        err
    end
  end

  def process_update(_), do: {:error, :invalid_update_payload}

  defp parse_status_update(%{
         "tracking_number" => tracking_number,
         "status" => status,
         "location" => location,
         "timestamp" => ts,
         "carrier_code" => carrier_code
       }) do
    update = %{
      tracking_number: tracking_number,
      status: String.to_atom(status),
      location: parse_location(location),
      occurred_at: parse_timestamp(ts),
      carrier: carrier_code
    }

    {:ok, update}
  end

  defp parse_status_update(_), do: {:error, :malformed_update}

  defp apply_update(%Shipment{} = shipment, update) do
    if shipment.status in @terminal_statuses do
      Logger.info("Ignoring update for terminal shipment", status: shipment.status)
      {:ok, shipment}
    else
      updated = %{shipment | status: update.status, last_location: update.location, updated_at: update.occurred_at}
      {:ok, updated}
    end
  end

  defp maybe_notify(%Shipment{status: status} = shipment) when status in @actionable_statuses do
    ShipmentNotifier.notify(shipment)
  end

  defp maybe_notify(_), do: :ok

  defp parse_location(%{"city" => city, "country" => country}), do: "#{city}, #{country}"
  defp parse_location(_), do: "Unknown"

  defp parse_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
```
