# Annotated Example — Code Smell

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `ShipmentTracker.fetch_status/1`
- **Affected function(s):** `ShipmentTracker.fetch_status/1`, `LogisticsController.track/2`
- **Short explanation:** `ShipmentTracker.fetch_status/1` raises a `ShipmentNotFoundError` when a tracking number has no record and a `TrackingNumberFormatError` when the number is malformed. Both are foreseeable, routine situations in a tracking API (users frequently enter wrong or expired numbers). The controller `LogisticsController.track/2` is therefore forced into `try/rescue` for standard request handling. No tuple-returning alternative is provided.

---

## Code

```elixir
defmodule ShipmentTracker do
  @moduledoc """
  Provides shipment status lookups for the logistics tracking subsystem.
  Integrates with carrier data and internal shipment records.
  """

  defmodule ShipmentNotFoundError do
    defexception [:message, :tracking_number]

    @impl true
    def exception(opts) do
      tn = Keyword.fetch!(opts, :tracking_number)
      %__MODULE__{
        message: "No shipment found for tracking number: #{tn}",
        tracking_number: tn
      }
    end
  end

  defmodule TrackingNumberFormatError do
    defexception [:message, :tracking_number]

    @impl true
    def exception(opts) do
      tn = Keyword.fetch!(opts, :tracking_number)
      %__MODULE__{
        message: "Invalid tracking number format: #{inspect(tn)}",
        tracking_number: tn
      }
    end
  end

  @tracking_regex ~r/^[A-Z]{2}\d{9}[A-Z]{2}$/

  # Simulated in-memory shipment store
  @known_shipments %{
    "AB123456789CD" => %{
      status: :in_transit,
      carrier: "FastShip",
      origin: "São Paulo, BR",
      destination: "Rio de Janeiro, BR",
      estimated_delivery: ~D[2026-05-25],
      events: [
        %{timestamp: ~U[2026-05-20 08:00:00Z], location: "São Paulo Hub", description: "Picked up"},
        %{timestamp: ~U[2026-05-20 14:00:00Z], location: "Campinas Relay", description: "In transit"}
      ]
    },
    "XY987654321ZW" => %{
      status: :delivered,
      carrier: "QuickCargo",
      origin: "Belo Horizonte, BR",
      destination: "Vitória, BR",
      estimated_delivery: ~D[2026-05-19],
      events: [
        %{timestamp: ~U[2026-05-18 09:30:00Z], location: "BH Warehouse", description: "Dispatched"},
        %{timestamp: ~U[2026-05-19 16:45:00Z], location: "Vitória DC", description: "Delivered"}
      ]
    }
  }

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because fetch_status/1 raises TrackingNumberFormatError
  # VALIDATION: and ShipmentNotFoundError for routine, anticipated conditions.
  # VALIDATION: Malformed and unrecognised tracking numbers are normal inputs in a
  # VALIDATION: public-facing tracking API. All callers are forced into try/rescue for
  # VALIDATION: ordinary request-handling logic because no {:ok, _} | {:error, _}
  # VALIDATION: alternative exists.
  def fetch_status(tracking_number) when is_binary(tracking_number) do
    normalized = String.upcase(String.trim(tracking_number))

    unless Regex.match?(@tracking_regex, normalized) do
      raise TrackingNumberFormatError, tracking_number: tracking_number
    end

    case Map.fetch(@known_shipments, normalized) do
      {:ok, shipment} ->
        Map.put(shipment, :tracking_number, normalized)

      :error ->
        raise ShipmentNotFoundError, tracking_number: normalized
    end
  end

  def fetch_status(_other) do
    raise TrackingNumberFormatError, tracking_number: nil
  end
  # VALIDATION: SMELL END

  def format_events(events) do
    Enum.map(events, fn e ->
      %{
        timestamp: DateTime.to_string(e.timestamp),
        location: e.location,
        description: e.description
      }
    end)
  end

  def status_label(:in_transit), do: "In Transit"
  def status_label(:delivered), do: "Delivered"
  def status_label(:pending), do: "Pending Pickup"
  def status_label(:exception), do: "Delivery Exception"
  def status_label(_), do: "Unknown"
end

defmodule LogisticsController do
  @moduledoc """
  HTTP controller exposing shipment tracking endpoints.
  """

  require Logger

  alias ShipmentTracker
  alias ShipmentTracker.{ShipmentNotFoundError, TrackingNumberFormatError}

  def track(conn, %{"tracking_number" => tn}) do
    # Forced to use try/rescue because ShipmentTracker.fetch_status/1 raises
    # exceptions instead of returning tagged tuples.
    try do
      shipment = ShipmentTracker.fetch_status(tn)

      response = %{
        tracking_number: shipment.tracking_number,
        status: ShipmentTracker.status_label(shipment.status),
        carrier: shipment.carrier,
        origin: shipment.origin,
        destination: shipment.destination,
        estimated_delivery: Date.to_string(shipment.estimated_delivery),
        events: ShipmentTracker.format_events(shipment.events)
      }

      send_json(conn, 200, response)
    rescue
      e in TrackingNumberFormatError ->
        Logger.info("Invalid tracking number submitted: #{inspect(tn)}")
        send_json(conn, 422, %{error: "invalid_tracking_number", detail: e.message})

      e in ShipmentNotFoundError ->
        Logger.info("Tracking lookup miss for: #{e.tracking_number}")
        send_json(conn, 404, %{error: "not_found", detail: e.message})
    end
  end

  defp send_json(conn, status, body) do
    Logger.debug("Responding #{status}: #{inspect(body)}")
    {conn, status, Jason.encode!(body)}
  end
end
```
