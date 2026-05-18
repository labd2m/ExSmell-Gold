# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `to_status_atom/1` function
- **Affected function(s):** `to_status_atom/1`, `enrich_shipment/1`
- **Short explanation:** The function converts shipment status strings returned by a third-party logistics API into atoms with `String.to_atom/1`. Since the carrier API may introduce new or misspelled status codes at any time, this creates unpredictable atom growth that the developer cannot control.

---

```elixir
defmodule Logistics.ShipmentTracker do
  @moduledoc """
  Polls the carrier API for shipment status updates and persists
  tracking events to the local database for downstream processing.
  """

  require Logger

  alias Logistics.{CarrierClient, ShipmentRepo, TrackingEvent, NotificationDispatcher}

  @poll_interval_ms 60_000
  @max_retries 3

  @spec poll_pending_shipments() :: {:ok, non_neg_integer()} | {:error, term()}
  def poll_pending_shipments do
    Logger.info("Starting shipment status poll")

    case ShipmentRepo.list_pending() do
      {:ok, shipments} ->
        results =
          shipments
          |> Enum.map(&fetch_and_update/1)
          |> Enum.reduce({0, 0}, fn
            {:ok, _}, {ok, err} -> {ok + 1, err}
            {:error, _}, {ok, err} -> {ok, err + 1}
          end)

        {updated, failed} = results
        Logger.info("Poll complete", updated: updated, failed: failed)
        {:ok, updated}

      {:error, reason} ->
        Logger.error("Failed to list pending shipments", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp fetch_and_update(%{tracking_number: tracking_number, carrier: carrier} = shipment) do
    case CarrierClient.fetch_status(carrier, tracking_number, retries: @max_retries) do
      {:ok, raw_status_data} ->
        with {:ok, enriched} <- enrich_shipment(raw_status_data),
             {:ok, event} <- persist_tracking_event(shipment, enriched),
             :ok <- maybe_notify(shipment, enriched) do
          {:ok, event}
        end

      {:error, :not_found} ->
        Logger.warning("Tracking number not found", tracking_number: tracking_number)
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Carrier API error",
          tracking_number: tracking_number,
          reason: inspect(reason)
        )
        {:error, reason}
    end
  end

  defp enrich_shipment(%{"status" => status} = raw) do
    with {:ok, status_atom} <- to_status_atom(status) do
      enriched = %TrackingEvent{
        status: status_atom,
        location: raw["location"],
        description: raw["description"],
        estimated_delivery: parse_date(raw["estimated_delivery"]),
        occurred_at: parse_datetime(raw["timestamp"])
      }

      {:ok, enriched}
    end
  end

  defp enrich_shipment(_), do: {:error, :malformed_status_response}

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to a
  # status string returned directly from a third-party carrier API. The carrier
  # can return any string value (new statuses, typos, locale variants), and
  # each unique string will create a new atom that is never garbage-collected,
  # leading to unbounded growth of the atom table.
  defp to_status_atom(status) when is_binary(status) do
    {:ok, String.to_atom(status)}
  end
  # VALIDATION: SMELL END

  defp to_status_atom(_), do: {:error, :invalid_status}

  defp persist_tracking_event(shipment, %TrackingEvent{} = event) do
    ShipmentRepo.insert_tracking_event(%{
      shipment_id: shipment.id,
      status: event.status,
      location: event.location,
      description: event.description,
      estimated_delivery: event.estimated_delivery,
      occurred_at: event.occurred_at
    })
  end

  defp maybe_notify(shipment, %TrackingEvent{status: :delivered} = event) do
    NotificationDispatcher.dispatch(:delivery_confirmed, %{
      shipment_id: shipment.id,
      customer_id: shipment.customer_id,
      delivered_at: event.occurred_at
    })
  end

  defp maybe_notify(shipment, %TrackingEvent{status: :exception} = event) do
    NotificationDispatcher.dispatch(:delivery_exception, %{
      shipment_id: shipment.id,
      customer_id: shipment.customer_id,
      description: event.description
    })
  end

  defp maybe_notify(_shipment, _event), do: :ok

  defp parse_date(nil), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
```
