# Annotated Example 14

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `ShipmentHandler.execute/1`
- **Affected function(s):** `execute/1`
- **Short explanation:** `execute/1` handles parcel dispatch, delivery confirmation, and return initiation — three distinct logistics operations on unrelated structs — all fused under one multi-clause function, making the codebase harder to navigate and document.

```elixir
defmodule ShipmentHandler do
  @moduledoc """
  Manages shipment lifecycle operations for the logistics platform.
  Handles parcel dispatch, delivery confirmation, and return initiation.
  """

  alias ShipmentHandler.{
    DispatchRequest,
    DeliveryConfirmation,
    ReturnRequest,
    CarrierClient,
    ShipmentStore,
    WarehouseNotifier,
    CustomerNotifier,
    LabelPrinter,
    AuditLog
  }

  require Logger

  @doc """
  Execute a shipment lifecycle action.

  Accepts a `%DispatchRequest{}`, `%DeliveryConfirmation{}`, or
  `%ReturnRequest{}` and performs the corresponding logistics operation.

  ## Examples

      iex> ShipmentHandler.execute(%DispatchRequest{order_id: "ORD-001", carrier: :fedex})
      {:ok, %{tracking_number: "FX123456789", label_url: "https://..."}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because parcel dispatch, delivery confirmation,
  # and return initiation are separate logistics workflows, each with distinct
  # integrations, data requirements, and downstream effects. Grouping them
  # under a single `execute/1` abuses multi-clause functions.

  def execute(%DispatchRequest{
        order_id: order_id,
        carrier: carrier,
        parcels: parcels,
        ship_from: ship_from,
        ship_to: ship_to
      }) do
    with {:ok, shipment} <- ShipmentStore.find_by_order(order_id),
         :ok <- validate_dispatch_ready(shipment),
         {:ok, booking} <-
           CarrierClient.book_shipment(carrier, %{
             parcels: parcels,
             from: ship_from,
             to: ship_to
           }),
         {:ok, label_url} <- LabelPrinter.generate(booking.tracking_number, carrier),
         {:ok, updated} <-
           ShipmentStore.mark_dispatched(shipment.id, booking.tracking_number),
         :ok <- CustomerNotifier.send_dispatch_notification(updated, label_url) do
      Logger.info("Dispatched order #{order_id} via #{carrier}: #{booking.tracking_number}")
      {:ok, %{tracking_number: booking.tracking_number, label_url: label_url}}
    end
  end

  # execute delivery confirmation received from carrier webhook
  def execute(%DeliveryConfirmation{
        tracking_number: tracking,
        delivered_at: delivered_at,
        signed_by: signed_by,
        proof_of_delivery_url: pod_url
      }) do
    with {:ok, shipment} <- ShipmentStore.find_by_tracking(tracking),
         {:ok, updated} <-
           ShipmentStore.mark_delivered(shipment.id, %{
             delivered_at: delivered_at,
             signed_by: signed_by,
             pod_url: pod_url
           }),
         :ok <- CustomerNotifier.send_delivery_notification(updated),
         :ok <-
           AuditLog.append(:delivery_confirmed, %{
             shipment_id: shipment.id,
             tracking: tracking,
             delivered_at: delivered_at
           }) do
      Logger.info("Delivery confirmed for tracking #{tracking}")
      {:ok, updated}
    end
  end

  # execute return request initiated by the customer
  def execute(%ReturnRequest{
        order_id: order_id,
        reason: reason,
        items: items,
        customer_id: customer_id
      })
      when reason in [:damaged, :wrong_item, :not_needed, :quality_issue] do
    with {:ok, shipment} <- ShipmentStore.find_by_order(order_id),
         :ok <- validate_returnable(shipment),
         {:ok, rma} <- ShipmentStore.create_rma(shipment.id, reason, items),
         {:ok, return_label} <-
           CarrierClient.book_return(shipment.carrier, shipment.ship_from, shipment.ship_to),
         :ok <- CustomerNotifier.send_return_instructions(customer_id, rma, return_label),
         :ok <- WarehouseNotifier.notify_incoming_return(rma) do
      Logger.info("Return initiated for order #{order_id}, RMA=#{rma.id}")
      {:ok, %{rma_id: rma.id, return_label_url: return_label.url}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_dispatch_ready(%{status: :ready_to_ship}), do: :ok
  defp validate_dispatch_ready(%{status: status}), do: {:error, {:not_ready, status}}

  defp validate_returnable(%{status: :delivered, delivered_at: delivered_at}) do
    days_since = Date.diff(Date.utc_today(), DateTime.to_date(delivered_at))

    if days_since <= 30 do
      :ok
    else
      {:error, :return_window_expired}
    end
  end

  defp validate_returnable(%{status: status}), do: {:error, {:not_returnable, status}}
end
```
