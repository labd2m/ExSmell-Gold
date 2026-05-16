# example_bad_11_clean

```elixir
defmodule Logistics.ShipmentStatusSyncer do
  @moduledoc """
  Synchronises shipment tracking state from carrier APIs into the
  internal logistics platform, triggering appropriate workflows per status.
  """

  alias Logistics.CarrierTrackingClient
  alias Logistics.ShipmentStore
  alias Logistics.ExceptionWorkflow
  alias Logistics.RetryScheduler
  alias Notifications.CustomerNotifier
  alias Logistics.AuditLogger

  @polling_interval_seconds 300
  @customs_hold_alert_hours 48

  def sync_all_active(warehouse_id) do
    with {:ok, shipments} <- ShipmentStore.list_active(warehouse_id) do
      results  = Enum.map(shipments, &sync_shipment_status(&1, warehouse_id))
      ok_count  = Enum.count(results, &match?({:ok, _}, &1))
      err_count = Enum.count(results, &match?({:error, _}, &1))
      {:ok, %{synced: ok_count, failed: err_count}}
    end
  end

  defp sync_shipment_status(shipment, warehouse_id) do
    case CarrierTrackingClient.fetch_status(shipment.tracking_number, shipment.carrier) do
      {:ok, %{status: "in_transit", location: loc, estimated_delivery: eta}} ->
        ShipmentStore.update_status(shipment.id, :in_transit, %{location: loc, eta: eta})
        {:ok, :in_transit}

      {:ok, %{status: "out_for_delivery", driver_id: driver, estimated_arrival: arr}} ->
        ShipmentStore.update_status(shipment.id, :out_for_delivery, %{driver_id: driver, eta: arr})
        CustomerNotifier.notify_out_for_delivery(shipment.customer_id, arr)
        {:ok, :out_for_delivery}

      {:ok, %{status: "delivered", delivered_at: ts, signature: sig}} ->
        ShipmentStore.mark_delivered(shipment.id, ts, sig)
        CustomerNotifier.notify_delivered(shipment.customer_id, shipment.id)
        AuditLogger.log(:shipment_delivered, warehouse_id, %{shipment_id: shipment.id, ts: ts})
        {:ok, :delivered}

      {:ok, %{status: "delivery_attempted", attempt_count: n, next_attempt: next}} ->
        ShipmentStore.update_status(shipment.id, :delivery_attempted, %{attempts: n, next: next})
        CustomerNotifier.notify_delivery_missed(shipment.customer_id, next)
        {:ok, :delivery_attempted}

      {:ok, %{status: "held_at_customs", customs_ref: ref, held_since: since}} ->
        ShipmentStore.update_status(shipment.id, :held_at_customs, %{ref: ref, since: since})
        if hours_since(since) > @customs_hold_alert_hours do
          ExceptionWorkflow.open_customs_hold(shipment.id, ref)
        end
        {:ok, :held_at_customs}

      {:ok, %{status: "returned_to_sender", return_ref: rref, returned_at: rts}} ->
        ShipmentStore.update_status(shipment.id, :returned, %{return_ref: rref, returned_at: rts})
        ExceptionWorkflow.open_return(shipment.id, rref)
        CustomerNotifier.notify_return(shipment.customer_id, rref)
        {:ok, :returned}

      {:ok, %{status: "lost", reported_at: rat}} ->
        ShipmentStore.update_status(shipment.id, :lost, %{reported_at: rat})
        ExceptionWorkflow.open_lost_claim(shipment.id)
        AuditLogger.log(:shipment_lost, warehouse_id, %{shipment_id: shipment.id})
        {:ok, :lost}

      {:ok, %{status: "cancelled", cancelled_by: by, reason: reason}} ->
        ShipmentStore.update_status(shipment.id, :cancelled, %{cancelled_by: by, reason: reason})
        AuditLogger.log(:shipment_cancelled, warehouse_id, %{shipment_id: shipment.id, by: by})
        {:ok, :cancelled}

      {:ok, %{status: unknown}} ->
        AuditLogger.log(:unknown_carrier_status, warehouse_id, %{status: unknown, shipment_id: shipment.id})
        {:error, {:unknown_status, unknown}}

      {:error, %{reason: :timeout}} ->
        RetryScheduler.schedule(shipment.id, :sync_status, @polling_interval_seconds)
        {:error, :carrier_timeout}

      {:error, reason} ->
        AuditLogger.log(:carrier_api_error, warehouse_id, %{reason: reason, shipment_id: shipment.id})
        {:error, :carrier_api_error}
    end
  end

  defp hours_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :second) / 3600
  end
end
```
