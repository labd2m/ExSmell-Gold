# Annotated Example

- **Smell name:** Comments
- **Expected smell location:** `ShipmentTracker.update_location/3`
- **Affected function(s):** `update_location/3`
- **Short explanation:** Documentation is written as regular `#` comments directly above the function head instead of using `@doc`, so it is invisible to Elixir's documentation infrastructure.

```elixir
defmodule MyApp.Logistics.ShipmentTracker do
  @moduledoc """
  Tracks real-time location updates for shipments in transit.
  Integrates with carrier APIs and maintains a full event history
  for audit and customer-facing tracking pages.
  """

  alias MyApp.Repo
  alias MyApp.Logistics.{Shipment, TrackingEvent, GeoUtils}

  require Logger

  @statuses [:pending, :picked_up, :in_transit, :out_for_delivery, :delivered, :failed]

  @doc """
  Looks up a shipment by its tracking number.

  Returns `{:ok, shipment}` or `{:error, :not_found}`.
  """
  def find_by_tracking_number(tracking_number) do
    case Repo.get_by(Shipment, tracking_number: tracking_number) do
      nil -> {:error, :not_found}
      shipment -> {:ok, shipment}
    end
  end

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because update_location/3 is documented using plain # comments
  # instead of @doc, rendering the documentation inaccessible to IEx.h/1 and ExDoc.

  # Updates the current geographic location of a shipment and appends a tracking event.
  #
  # Arguments:
  #   shipment_id  - integer primary key of the shipment record.
  #   coordinates  - map with float keys :lat and :lng representing the new position.
  #   carrier_meta - optional map of carrier-provided metadata (e.g. checkpoint name, ETA).
  #
  # Side effects:
  #   - Persists a new TrackingEvent row in the database.
  #   - Updates the :last_location and :last_seen_at fields on the Shipment.
  #   - Broadcasts a PubSub message to the "shipment:{id}" topic.
  #
  # Returns {:ok, event} or {:error, reason}.
  def update_location(shipment_id, %{lat: lat, lng: lng} = coordinates, carrier_meta \\ %{}) do
  # VALIDATION: SMELL END
    with {:ok, shipment} <- fetch_shipment(shipment_id),
         :ok <- validate_coordinates(lat, lng) do
      event_attrs = %{
        shipment_id: shipment.id,
        lat: lat,
        lng: lng,
        carrier_meta: carrier_meta,
        recorded_at: DateTime.utc_now()
      }

      shipment_attrs = %{
        last_lat: lat,
        last_lng: lng,
        last_seen_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        {:ok, event} =
          TrackingEvent.changeset(%TrackingEvent{}, event_attrs)
          |> Repo.insert()

        shipment
        |> Shipment.changeset(shipment_attrs)
        |> Repo.update!()

        Phoenix.PubSub.broadcast(
          MyApp.PubSub,
          "shipment:#{shipment.id}",
          {:location_updated, event}
        )

        event
      end)
    end
  end

  @doc """
  Transitions a shipment to a new status.

  Valid status transitions are enforced; an invalid transition returns
  `{:error, :invalid_transition}`.
  """
  def transition_status(shipment_id, new_status) when new_status in @statuses do
    with {:ok, shipment} <- fetch_shipment(shipment_id),
         :ok <- validate_transition(shipment.status, new_status) do
      shipment
      |> Shipment.changeset(%{status: new_status})
      |> Repo.update()
    end
  end

  def transition_status(_shipment_id, _invalid_status), do: {:error, :unknown_status}

  @doc """
  Returns the full ordered list of tracking events for a shipment.
  """
  def tracking_history(shipment_id) do
    events =
      TrackingEvent
      |> TrackingEvent.for_shipment(shipment_id)
      |> TrackingEvent.ordered()
      |> Repo.all()

    {:ok, events}
  end

  @doc """
  Calculates the approximate total distance travelled based on recorded coordinates.

  Returns the distance in kilometres as a float.
  """
  def total_distance(shipment_id) do
    {:ok, events} = tracking_history(shipment_id)

    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc ->
      acc + GeoUtils.haversine(a.lat, a.lng, b.lat, b.lng)
    end)
  end

  # --- Private helpers ---

  defp fetch_shipment(id) do
    case Repo.get(Shipment, id) do
      nil -> {:error, :shipment_not_found}
      s -> {:ok, s}
    end
  end

  defp validate_coordinates(lat, lng)
       when lat >= -90 and lat <= 90 and lng >= -180 and lng <= 180,
       do: :ok

  defp validate_coordinates(_, _), do: {:error, :invalid_coordinates}

  defp validate_transition(:in_transit, :out_for_delivery), do: :ok
  defp validate_transition(:picked_up, :in_transit), do: :ok
  defp validate_transition(:pending, :picked_up), do: :ok
  defp validate_transition(:out_for_delivery, :delivered), do: :ok
  defp validate_transition(:out_for_delivery, :failed), do: :ok
  defp validate_transition(_, _), do: {:error, :invalid_transition}
end
```
