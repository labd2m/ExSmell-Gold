```elixir
defmodule DeliveryStatusUpdater do
  @moduledoc """
  Records delivery lifecycle events for tracked shipments.
  Enforces event ordering, deduplication, and valid state transitions.
  """

  defmodule DuplicateEventError do
    defexception [:message, :event_id, :shipment_id]
  end

  defmodule ShipmentNotFoundError do
    defexception [:message, :shipment_id]
  end

  defmodule IllegalTransitionError do
    defexception [:message, :shipment_id, :from_status, :to_status]
  end

  defmodule UnknownEventCodeError do
    defexception [:message, :event_code]
  end

  defmodule StaleEventError do
    defexception [:message, :event_id, :event_at, :last_event_at]
  end

  @valid_event_codes ~w(PICKUP_SCANNED IN_TRANSIT OUT_FOR_DELIVERY DELIVERED FAILED_ATTEMPT RETURNED)

  @valid_transitions %{
    :pending => [:in_transit],
    :in_transit => [:in_transit, :out_for_delivery, :failed_attempt, :returned],
    :out_for_delivery => [:delivered, :failed_attempt],
    :failed_attempt => [:out_for_delivery, :returned],
    :delivered => [],
    :returned => []
  }

  @event_to_status %{
    "PICKUP_SCANNED" => :in_transit,
    "IN_TRANSIT" => :in_transit,
    "OUT_FOR_DELIVERY" => :out_for_delivery,
    "DELIVERED" => :delivered,
    "FAILED_ATTEMPT" => :failed_attempt,
    "RETURNED" => :returned
  }

  @shipments %{
    "SHP-001" => %{
      id: "SHP-001",
      status: :in_transit,
      last_event_at: ~U[2025-09-12 08:00:00Z],
      processed_event_ids: MapSet.new(["EVT-existing-1"])
    },
    "SHP-002" => %{
      id: "SHP-002",
      status: :delivered,
      last_event_at: ~U[2025-09-10 14:30:00Z],
      processed_event_ids: MapSet.new()
    }
  }

  def record_event(shipment_id, event) do
    shipment = Map.get(@shipments, shipment_id)

    if is_nil(shipment) do
      raise ShipmentNotFoundError,
        message: "Shipment '#{shipment_id}' not found in tracking system",
        shipment_id: shipment_id
    end

    event_code = Map.get(event, :code)

    unless event_code in @valid_event_codes do
      raise UnknownEventCodeError,
        message:
          "Event code '#{event_code}' is not recognised. " <>
            "Valid codes: #{Enum.join(@valid_event_codes, ", ")}",
        event_code: event_code
    end

    if MapSet.member?(shipment.processed_event_ids, event.id) do
      raise DuplicateEventError,
        message: "Event '#{event.id}' has already been applied to shipment #{shipment_id}",
        event_id: event.id,
        shipment_id: shipment_id
    end

    if DateTime.compare(event.occurred_at, shipment.last_event_at) == :lt do
      raise StaleEventError,
        message:
          "Event #{event.id} at #{event.occurred_at} is older than last recorded event at #{shipment.last_event_at}",
        event_id: event.id,
        event_at: event.occurred_at,
        last_event_at: shipment.last_event_at
    end

    new_status = Map.fetch!(@event_to_status, event_code)
    allowed_next = Map.get(@valid_transitions, shipment.status, [])

    unless new_status in allowed_next do
      raise IllegalTransitionError,
        message:
          "Cannot transition shipment #{shipment_id} from '#{shipment.status}' to '#{new_status}' via event #{event_code}",
        shipment_id: shipment_id,
        from_status: shipment.status,
        to_status: new_status
    end

    %{
      shipment_id: shipment_id,
      previous_status: shipment.status,
      new_status: new_status,
      event_id: event.id,
      event_code: event_code,
      recorded_at: DateTime.utc_now()
    }
  end
end

defmodule WarehouseWebhookHandler do
  @moduledoc """
  Processes inbound delivery status webhooks from warehouse and carrier systems.
  Idempotently acknowledges or rejects each event payload.
  """

  require Logger

  def handle(%{shipment_id: shipment_id, event: event} = _payload) do
    Logger.debug("Webhook received for shipment #{shipment_id}, event #{event.id}")

    # and unknown codes are expected in high-throughput webhook pipelines
    # (at-least-once delivery, carrier integration mismatches). The handler
    # must use try...rescue as its primary branching mechanism because
    # DeliveryStatusUpdater provides no tuple-based interface.
    try do
      update = DeliveryStatusUpdater.record_event(shipment_id, event)

      Logger.info(
        "Shipment #{shipment_id} transitioned #{update.previous_status} → #{update.new_status} via #{update.event_code}"
      )

      {:ok, :recorded, update}
    rescue
      e in DeliveryStatusUpdater.DuplicateEventError ->
        Logger.debug("Duplicate event #{e.event_id} for shipment #{e.shipment_id}; acknowledging idempotently")
        {:ok, :duplicate}

      e in DeliveryStatusUpdater.StaleEventError ->
        Logger.debug("Stale event #{e.event_id} (#{e.event_at} < #{e.last_event_at}); discarding")
        {:ok, :stale}

      e in DeliveryStatusUpdater.ShipmentNotFoundError ->
        Logger.warning("Webhook for unknown shipment #{e.shipment_id}")
        {:error, :shipment_not_found}

      e in DeliveryStatusUpdater.UnknownEventCodeError ->
        Logger.warning("Unrecognised event code '#{e.event_code}' in webhook")
        {:error, {:unknown_event_code, e.event_code}}

      e in DeliveryStatusUpdater.IllegalTransitionError ->
        Logger.error(
          "Illegal transition #{e.from_status} → #{e.to_status} for shipment #{e.shipment_id}"
        )
        {:error, {:illegal_transition, e.from_status, e.to_status}}
    end
  end

  def handle(_payload) do
    Logger.warning("Malformed webhook payload received")
    {:error, :malformed_payload}
  end
end
```
