# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `Logistics.TrackingService` module — shipment event representation |
| **Affected functions** | `record_event/3`, `get_current_status/1`, `compute_eta/2`, `notify_recipient/2` |
| **Short explanation** | Shipment tracking events are described by a plain `String.t()` location (e.g., `"Warehouse São Paulo - BR"`) and a plain `String.t()` status code (e.g., `"IN_TRANSIT"`) rather than a `%TrackingEvent{status: atom(), location: %Address{}, occurred_at: DateTime.t()}` struct. Each function must parse and validate both strings independently, producing scattered and fragile string-matching logic. |

```elixir
defmodule Logistics.TrackingService do
  @moduledoc """
  Records and queries real-time shipment tracking events.
  Provides status lookups, ETA estimation, and recipient
  notifications as packages move through the logistics network.
  """

  require Logger

  alias Logistics.Repo
  alias Logistics.Schema.{Shipment, TrackingEvent}
  alias Logistics.Notifications.PushGateway

  @valid_statuses ~w(CREATED PICKED_UP IN_TRANSIT OUT_FOR_DELIVERY DELIVERED FAILED RETURNED)
  @terminal_statuses ~w(DELIVERED FAILED RETURNED)
  @transit_hours_per_leg 8

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because tracking events are expressed with
  # a plain string `status` (e.g., "IN_TRANSIT") and a plain string `location`
  # (e.g., "Hub Campinas - BR") instead of a structured
  # %TrackingEvent{status: :in_transit, location: %Address{}, occurred_at: DateTime.t()}.
  # Every function must validate and parse these strings independently, with
  # the location's country code, city, and facility name embedded in a single
  # free-form binary.

  @spec record_event(String.t(), String.t(), String.t()) ::
          {:ok, TrackingEvent.t()} | {:error, term()}
  def record_event(tracking_number, status, location_string)
      when is_binary(tracking_number) and is_binary(status) and is_binary(location_string) do
    with :ok <- validate_status(status),
         {:ok, shipment} <- fetch_shipment(tracking_number),
         :ok <- validate_transition(shipment.current_status, status),
         {:ok, event} <- persist_event(shipment, status, location_string) do
      country = extract_country_from_location(location_string)
      facility = extract_facility_from_location(location_string)

      Logger.info(
        "Tracking event: #{tracking_number} status=#{status} facility=#{facility} country=#{country}"
      )

      update_shipment_status(shipment, status)
      {:ok, event}
    end
  end

  @spec get_current_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_current_status(tracking_number) when is_binary(tracking_number) do
    case fetch_shipment(tracking_number) do
      {:ok, shipment} ->
        latest_event =
          shipment
          |> Repo.preload(:tracking_events)
          |> Map.get(:tracking_events, [])
          |> Enum.max_by(& &1.occurred_at, DateTime, fn -> nil end)

        location_info =
          if latest_event do
            %{
              raw: latest_event.location,
              country: extract_country_from_location(latest_event.location),
              facility: extract_facility_from_location(latest_event.location)
            }
          else
            nil
          end

        {:ok, %{
          tracking_number: tracking_number,
          status: shipment.current_status,
          last_location: location_info,
          is_terminal: shipment.current_status in @terminal_statuses
        }}

      error ->
        error
    end
  end

  @spec compute_eta(String.t(), String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def compute_eta(tracking_number, destination_location_string)
      when is_binary(tracking_number) and is_binary(destination_location_string) do
    with {:ok, shipment} <- fetch_shipment(tracking_number) do
      events =
        shipment
        |> Repo.preload(:tracking_events)
        |> Map.get(:tracking_events, [])

      remaining_legs = estimate_remaining_legs(shipment.current_status, destination_location_string)
      dest_country = extract_country_from_location(destination_location_string)
      last_event_time = events |> Enum.map(& &1.occurred_at) |> Enum.max(DateTime, fn -> DateTime.utc_now() end)

      hours_to_add = remaining_legs * @transit_hours_per_leg + (if dest_country != "BR", do: 48, else: 0)
      eta = DateTime.add(last_event_time, hours_to_add * 3600)

      {:ok, eta}
    end
  end

  @spec notify_recipient(String.t(), String.t()) :: :ok | {:error, term()}
  def notify_recipient(tracking_number, status) when is_binary(status) do
    with :ok <- validate_status(status),
         {:ok, shipment} <- fetch_shipment(tracking_number) do
      message =
        case status do
          "OUT_FOR_DELIVERY" -> "Your package is out for delivery today!"
          "DELIVERED" -> "Your package has been delivered."
          "FAILED" -> "Delivery attempt failed. Please reschedule."
          _ -> "Your shipment status has been updated to #{status}."
        end

      PushGateway.send(shipment.recipient_id, message)
    end
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp validate_status(status) when status in @valid_statuses, do: :ok
  defp validate_status(s), do: {:error, {:invalid_status, s}}

  defp fetch_shipment(tracking_number) do
    case Repo.get_by(Shipment, tracking_number: tracking_number) do
      nil -> {:error, {:shipment_not_found, tracking_number}}
      s -> {:ok, s}
    end
  end

  defp validate_transition(current, next) do
    allowed = %{
      "CREATED" => ~w(PICKED_UP),
      "PICKED_UP" => ~w(IN_TRANSIT),
      "IN_TRANSIT" => ~w(IN_TRANSIT OUT_FOR_DELIVERY FAILED RETURNED),
      "OUT_FOR_DELIVERY" => ~w(DELIVERED FAILED),
      "DELIVERED" => [],
      "FAILED" => ~w(RETURNED IN_TRANSIT),
      "RETURNED" => []
    }

    if next in Map.get(allowed, current, []) do
      :ok
    else
      {:error, {:invalid_transition, current, next}}
    end
  end

  defp extract_country_from_location(location_string) do
    location_string |> String.split(" - ") |> List.last() |> String.trim()
  end

  defp extract_facility_from_location(location_string) do
    location_string |> String.split(" - ") |> List.first() |> String.trim()
  end

  defp estimate_remaining_legs(status, _dest) do
    case status do
      "IN_TRANSIT" -> 2
      "OUT_FOR_DELIVERY" -> 1
      _ -> 3
    end
  end

  defp persist_event(shipment, status, location) do
    attrs = %{
      shipment_id: shipment.id,
      status: status,
      location: location,
      occurred_at: DateTime.utc_now()
    }

    %TrackingEvent{} |> TrackingEvent.changeset(attrs) |> Repo.insert()
  end

  defp update_shipment_status(shipment, status) do
    shipment |> Shipment.changeset(%{current_status: status}) |> Repo.update()
  end
end
```
