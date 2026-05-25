# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `ShipmentTracker` module — functions `status_label/1`, `next_allowed_transitions/1`, and `customer_notification_template/1`
- **Affected functions:** `status_label/1`, `next_allowed_transitions/1`, `customer_notification_template/1`
- **Short explanation:** The same `case status` branching over `:pending`, `:in_transit`, `:out_for_delivery`, `:delivered`, and `:returned` is repeated in three separate functions. Adding a new shipment status requires updating every case block, which is the Switch Statements smell.

---

```elixir
defmodule ShipmentTracker do
  @moduledoc """
  Manages the lifecycle of shipments, including status transitions,
  customer-facing labels, notification templates, and event logging
  for the logistics platform.
  """

  require Logger

  @statuses [:pending, :in_transit, :out_for_delivery, :delivered, :returned]

  def valid_statuses, do: @statuses

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over status
  # (:pending, :in_transit, :out_for_delivery, :delivered, :returned) is duplicated
  # in status_label/1, next_allowed_transitions/1, and customer_notification_template/1.
  # Every new status requires parallel edits across all three functions.

  @doc """
  Returns a human-readable label for the given shipment status.
  """
  def status_label(%{status: status}) do
    case status do
      :pending -> "Awaiting Pickup"
      :in_transit -> "In Transit"
      :out_for_delivery -> "Out for Delivery"
      :delivered -> "Delivered"
      :returned -> "Returned to Sender"
      _ -> "Unknown Status"
    end
  end

  @doc """
  Returns the list of statuses that are valid transitions from the current status.
  """
  def next_allowed_transitions(%{status: status}) do
    case status do
      :pending -> [:in_transit, :returned]
      :in_transit -> [:out_for_delivery, :returned]
      :out_for_delivery -> [:delivered, :returned]
      :delivered -> []
      :returned -> []
      _ -> []
    end
  end

  @doc """
  Returns the notification template identifier to use when informing the customer
  of the shipment reaching the given status.
  """
  def customer_notification_template(%{status: status}) do
    case status do
      :pending -> "shipment_awaiting_pickup"
      :in_transit -> "shipment_in_transit"
      :out_for_delivery -> "shipment_out_for_delivery"
      :delivered -> "shipment_delivered"
      :returned -> "shipment_returned"
      _ -> "shipment_generic_update"
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Attempts to transition a shipment to a new status, returning the updated shipment
  or an error if the transition is not permitted.
  """
  def transition(%{status: _current_status} = shipment, new_status) do
    allowed = next_allowed_transitions(shipment)

    if new_status in allowed do
      updated = %{shipment | status: new_status, updated_at: DateTime.utc_now()}
      Logger.info("Shipment #{shipment.tracking_number} transitioned to #{new_status}.")
      {:ok, updated}
    else
      Logger.warning(
        "Invalid transition for #{shipment.tracking_number}: #{shipment.status} -> #{new_status}"
      )

      {:error, :invalid_transition}
    end
  end

  @doc """
  Builds a tracking event struct and appends it to the shipment history.
  """
  def record_event(%{history: history} = shipment, event_type, metadata \\ %{}) do
    event = %{
      event_type: event_type,
      status_label: status_label(shipment),
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }

    {:ok, %{shipment | history: [event | history]}}
  end

  @doc """
  Returns full tracking details for a shipment, suitable for a customer-facing API.
  """
  def tracking_summary(%{} = shipment) do
    %{
      tracking_number: shipment.tracking_number,
      status: shipment.status,
      label: status_label(shipment),
      estimated_delivery: Map.get(shipment, :estimated_delivery),
      last_update: Map.get(shipment, :updated_at),
      notification_template: customer_notification_template(shipment)
    }
  end

  @doc """
  Processes a batch of incoming carrier scan events and applies status transitions.
  """
  def process_scan_events(shipments_by_id, scan_events) when is_list(scan_events) do
    Enum.reduce(scan_events, {shipments_by_id, []}, fn event, {shipments, errors} ->
      shipment = Map.get(shipments, event.shipment_id)

      if is_nil(shipment) do
        {shipments, [{:not_found, event.shipment_id} | errors]}
      else
        case transition(shipment, event.new_status) do
          {:ok, updated} ->
            {Map.put(shipments, event.shipment_id, updated), errors}

          {:error, reason} ->
            {shipments, [{reason, event.shipment_id} | errors]}
        end
      end
    end)
  end
end
```
