# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `ShipmentTracker.status_label/1` and `ShipmentTracker.status_sort_priority/1`
- **Affected functions:** `status_label/1`, `status_sort_priority/1`
- **Short explanation:** The same `case` branching over shipment status atoms (`:pending`, `:in_transit`, `:out_for_delivery`, `:delivered`, `:failed`) is duplicated in two separate functions. Every time a new status is introduced, both functions must be updated in parallel.

---

```elixir
defmodule ShipmentTracker do
  @moduledoc """
  Provides tracking information, display utilities, and sorting logic
  for shipments across multiple carriers in a logistics platform.
  """

  alias ShipmentTracker.{Shipment, Carrier, TrackingEvent}

  @type shipment_status ::
          :pending
          | :picked_up
          | :in_transit
          | :out_for_delivery
          | :delivered
          | :failed
          | :returned

  @spec build_tracking_summary(Shipment.t()) :: map()
  def build_tracking_summary(%Shipment{} = shipment) do
    events = load_tracking_events(shipment.tracking_number)
    carrier = Carrier.get!(shipment.carrier_id)

    %{
      tracking_number: shipment.tracking_number,
      carrier_name: carrier.display_name,
      status: shipment.status,
      status_label: status_label(shipment.status),
      priority: status_sort_priority(shipment.status),
      estimated_delivery: shipment.estimated_delivery,
      events: Enum.map(events, &format_event/1),
      last_updated: shipment.updated_at
    }
  end

  @spec list_active_shipments([Shipment.t()]) :: [map()]
  def list_active_shipments(shipments) do
    shipments
    |> Enum.reject(&(&1.status == :delivered))
    |> Enum.reject(&(&1.status == :returned))
    |> Enum.sort_by(&status_sort_priority(&1.status))
    |> Enum.map(&build_tracking_summary/1)
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on shipment status
  # also appears in `status_sort_priority/1` below. Both functions enumerate the
  # identical set of status atoms, so introducing a new status requires updating both.
  @spec status_label(shipment_status()) :: String.t()
  def status_label(status) do
    case status do
      :pending          -> "Awaiting Pickup"
      :picked_up        -> "Picked Up"
      :in_transit       -> "In Transit"
      :out_for_delivery -> "Out for Delivery"
      :delivered        -> "Delivered"
      :failed           -> "Delivery Failed"
      :returned         -> "Returned to Sender"
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on shipment status
  # already appeared in `status_label/1` above. All status atoms are repeated here,
  # requiring parallel maintenance whenever the status domain changes.
  @spec status_sort_priority(shipment_status()) :: integer()
  def status_sort_priority(status) do
    case status do
      :out_for_delivery -> 1
      :in_transit       -> 2
      :picked_up        -> 3
      :pending          -> 4
      :failed           -> 5
      :delivered        -> 6
      :returned         -> 7
    end
  end
  # VALIDATION: SMELL END

  @spec can_cancel?(Shipment.t()) :: boolean()
  def can_cancel?(%Shipment{status: status}) do
    status in [:pending, :picked_up]
  end

  @spec format_event(TrackingEvent.t()) :: map()
  defp format_event(%TrackingEvent{} = event) do
    %{
      timestamp: event.occurred_at,
      location: event.location,
      description: event.description
    }
  end

  @spec load_tracking_events(String.t()) :: [TrackingEvent.t()]
  defp load_tracking_events(tracking_number) do
    TrackingEvent
    |> TrackingEvent.for_tracking_number(tracking_number)
    |> TrackingEvent.order_by_time()
    |> Repo.all()
  end
end
```
