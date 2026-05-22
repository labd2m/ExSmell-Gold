# Annotated Example — Code Smell: Comments

- **Smell name:** Comments
- **Expected smell location:** `MyApp.Logistics.ShipmentTracker` module, function `update_status/3`
- **Affected function(s):** `update_status/3`, `estimate_delivery/2`
- **Short explanation:** The author wrote detailed, multi-line `#` prose comments above both public functions to explain parameters, return values, and behaviour. This is exactly what `@doc` is designed for in Elixir. By using plain comments, the documentation is inaccessible at runtime, does not appear in generated HTML docs, and is lost to any consumer of the module via `IEx.Helpers.h/1`.

```elixir
defmodule MyApp.Logistics.ShipmentTracker do
  @moduledoc false

  require Logger

  alias MyApp.Logistics.{Shipment, Carrier, DeliveryWindow}
  alias MyApp.Repo
  alias MyApp.Notifications

  @valid_statuses ~w(pending picked_up in_transit out_for_delivery delivered failed returned)a
  @delivery_buffer_hours 2

  # Updates the status of a shipment identified by `tracking_number`.
  # `new_status` must be one of:
  #   :pending | :picked_up | :in_transit | :out_for_delivery |
  #   :delivered | :failed | :returned
  # `metadata` is an optional map that may contain:
  #   - :location (string) — current GPS/city location of the parcel
  #   - :carrier_event_code (string) — raw event code from the carrier API
  #   - :timestamp (DateTime) — time the event occurred on the carrier side
  # Returns {:ok, updated_shipment} when the transition is valid,
  # {:error, :invalid_status} for unknown statuses, or
  # {:error, :invalid_transition} when the state machine rejects the move.
  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `update_status/3` is documented
  # VALIDATION: entirely through `#` comments. `@doc` should be used so the
  # VALIDATION: documentation is available via `h/1` in IEx and ExDoc output.
  def update_status(tracking_number, new_status, metadata \\ %{})
      when is_binary(tracking_number) do
    # VALIDATION: SMELL END
    if new_status not in @valid_statuses do
      {:error, :invalid_status}
    else
      case Repo.get_by(Shipment, tracking_number: tracking_number) do
        nil ->
          {:error, :not_found}

        %Shipment{status: current} = shipment ->
          if valid_transition?(current, new_status) do
            changes = %{
              status: new_status,
              last_event_at: Map.get(metadata, :timestamp, DateTime.utc_now()),
              last_location: Map.get(metadata, :location),
              carrier_event_code: Map.get(metadata, :carrier_event_code),
              updated_at: DateTime.utc_now()
            }

            updated = Map.merge(shipment, changes)
            maybe_notify(updated, new_status)
            Logger.info("Shipment #{tracking_number} transitioned #{current} -> #{new_status}")
            {:ok, updated}
          else
            {:error, :invalid_transition}
          end
      end
    end
  end

  # Estimates the delivery window for a given shipment struct.
  # Uses the carrier's average transit time for the origin-destination pair
  # and adds a configurable buffer (@delivery_buffer_hours) to produce a range.
  # `carrier` must be a %Carrier{} struct with :avg_transit_hours populated.
  # Returns {:ok, %DeliveryWindow{earliest: dt, latest: dt}} or
  # {:error, :no_transit_data} when the carrier has no historical data.
  def estimate_delivery(%Shipment{origin: origin, destination: dest}, %Carrier{} = carrier) do
    case DeliveryWindow.fetch_avg(carrier, origin, dest) do
      {:ok, avg_hours} ->
        now = DateTime.utc_now()
        earliest = DateTime.add(now, avg_hours * 3600, :second)
        latest = DateTime.add(now, (avg_hours + @delivery_buffer_hours) * 3600, :second)
        {:ok, %DeliveryWindow{earliest: earliest, latest: latest}}

      :error ->
        {:error, :no_transit_data}
    end
  end

  defp valid_transition?(:pending, :picked_up), do: true
  defp valid_transition?(:picked_up, :in_transit), do: true
  defp valid_transition?(:in_transit, :in_transit), do: true
  defp valid_transition?(:in_transit, :out_for_delivery), do: true
  defp valid_transition?(:out_for_delivery, :delivered), do: true
  defp valid_transition?(:out_for_delivery, :failed), do: true
  defp valid_transition?(:failed, :returned), do: true
  defp valid_transition?(_, _), do: false

  defp maybe_notify(%Shipment{customer_id: cid} = shipment, :out_for_delivery) do
    Notifications.send_push(cid, "Your parcel is out for delivery!", %{
      tracking: shipment.tracking_number
    })
  end

  defp maybe_notify(%Shipment{customer_id: cid} = shipment, :delivered) do
    Notifications.send_push(cid, "Your parcel has been delivered!", %{
      tracking: shipment.tracking_number
    })
  end

  defp maybe_notify(_shipment, _status), do: :ok
end
```
