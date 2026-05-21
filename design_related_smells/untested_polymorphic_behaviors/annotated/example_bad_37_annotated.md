## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `build_tracking_label/1` — the `"#{carrier_code}"` string interpolation
- **Affected function(s):** `Logistics.ShipmentTracker.build_tracking_label/1`
- **Short explanation:** String interpolation (`"#{...}"`) uses the `String.Chars` protocol internally. The `carrier_code` parameter has no guard restricting it to types that implement the protocol. Passing a `Map`, `Tuple`, or list will raise `Protocol.UndefinedError` at runtime.

```elixir
defmodule Logistics.ShipmentTracker do
  @moduledoc """
  Manages shipment tracking lifecycle: label generation, status updates, and
  carrier event ingestion for outbound logistics operations.
  """

  alias Logistics.{Carrier, Shipment, TrackingEvent}

  @label_prefix "TRK"
  @supported_statuses ~w(pending in_transit out_for_delivery delivered failed)a

  def register_shipment(order_id, destination, carrier_opts) do
    carrier_code = Keyword.fetch!(carrier_opts, :carrier_code)
    service_level = Keyword.get(carrier_opts, :service_level, :standard)
    declared_weight = Keyword.get(carrier_opts, :weight_kg, 0.0)

    with {:ok, carrier} <- Carrier.lookup(carrier_code),
         :ok <- Carrier.validate_service(carrier, service_level),
         {:ok, label} <- build_tracking_label(carrier_code) do
      shipment = %Shipment{
        order_id: order_id,
        tracking_number: label,
        carrier: carrier,
        service_level: service_level,
        destination: destination,
        declared_weight_kg: declared_weight,
        status: :pending,
        registered_at: DateTime.utc_now(),
        events: []
      }

      {:ok, shipment}
    end
  end

  def record_event(%Shipment{} = shipment, event_type, location, timestamp \\ nil) do
    ts = timestamp || DateTime.utc_now()

    unless event_type in @supported_statuses do
      raise ArgumentError, "Unsupported tracking event type: #{inspect(event_type)}"
    end

    event = %TrackingEvent{
      type: event_type,
      location: location,
      occurred_at: ts
    }

    updated = %{shipment | status: event_type, events: shipment.events ++ [event]}
    {:ok, updated}
  end

  def latest_location(%Shipment{events: []}), do: {:error, :no_events}

  def latest_location(%Shipment{events: events}) do
    event = Enum.max_by(events, & &1.occurred_at, DateTime)
    {:ok, event.location}
  end

  def estimated_delivery(%Shipment{} = shipment) do
    case Carrier.get_eta(shipment.carrier, shipment.destination) do
      {:ok, eta} -> {:ok, eta}
      {:error, _} -> {:error, :eta_unavailable}
    end
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because the string interpolation `"#{carrier_code}"`
  # VALIDATION: uses the `String.Chars` protocol internally. No guard clause restricts
  # VALIDATION: `carrier_code` to types implementing the protocol (e.g., binary or atom).
  # VALIDATION: A caller passing a Map, Tuple, PID, or list will trigger a
  # VALIDATION: `Protocol.UndefinedError` at runtime without any meaningful error message.
  def build_tracking_label(carrier_code) do
    sequence = :erlang.unique_integer([:positive, :monotonic])
    date_segment = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "")

    label = "#{@label_prefix}-#{carrier_code}-#{date_segment}-#{sequence}"
    {:ok, label}
  end
  # VALIDATION: SMELL END

  def summarize(%Shipment{} = shipment) do
    %{
      tracking_number: shipment.tracking_number,
      order_id: shipment.order_id,
      status: shipment.status,
      carrier: shipment.carrier.name,
      service_level: shipment.service_level,
      event_count: length(shipment.events),
      registered_at: DateTime.to_iso8601(shipment.registered_at)
    }
  end

  def format_event_log(%Shipment{events: events}) do
    Enum.map(events, fn event ->
      "[#{DateTime.to_iso8601(event.occurred_at)}] #{event.type} @ #{event.location}"
    end)
  end
end
```
