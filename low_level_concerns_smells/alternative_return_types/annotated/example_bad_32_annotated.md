# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Logistics.ShipmentTracker.get_status/2`, around the `opts[:verbose]` and `opts[:history]` checks
- **Affected function(s):** `get_status/2`
- **Short explanation:** The function returns a plain atom, a `%{status: atom, location: string}` map, or a `[%TrackingEvent{}]` list depending on the options, making it impossible to write a single pattern-match at the call-site without knowing which options were used.

---

```elixir
defmodule Logistics.ShipmentTracker do
  @moduledoc """
  Tracks the current status and location of shipments across carriers.
  Integrates with internal event logs and external carrier APIs.
  """

  alias Logistics.Repo
  alias Logistics.Schema.{Shipment, TrackingEvent}
  alias Logistics.Carriers

  require Logger

  @doc """
  Retrieves the current status of a shipment.

  ## Options

    * `:verbose` - When `true`, returns a detailed map:
      `%{status: atom, location: string, carrier: string, updated_at: DateTime.t()}`
      instead of just the status atom.
    * `:history` - When `true`, returns the full list of `%TrackingEvent{}`
      structs ordered from most recent to oldest. Overrides `:verbose`.

  ## Examples

      iex> get_status("TRACK-001")
      :in_transit

      iex> get_status("TRACK-001", verbose: true)
      %{status: :in_transit, location: "Chicago, IL", carrier: "FedEx", updated_at: ~U[...]}

      iex> get_status("TRACK-001", history: true)
      [%TrackingEvent{status: :in_transit, ...}, %TrackingEvent{status: :picked_up, ...}]

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because the return type shifts from a bare atom,
  # VALIDATION: to a rich map, to a list of structs based on opts. Any code that
  # VALIDATION: calls this function must externally track which options were used
  # VALIDATION: before safely consuming the result. There is no stable contract.
  def get_status(tracking_number, opts \\ []) when is_list(opts) do
    shipment = Repo.get_by!(Shipment, tracking_number: tracking_number)

    cond do
      opts[:history] == true ->
        TrackingEvent
        |> Repo.all_by(shipment_id: shipment.id)
        |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})

      opts[:verbose] == true ->
        latest_event = latest_tracking_event(shipment.id)

        %{
          status: shipment.status,
          location: latest_event && latest_event.location,
          carrier: shipment.carrier,
          updated_at: shipment.updated_at
        }

      true ->
        shipment.status
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Records a new tracking event for a shipment.
  """
  def record_event(tracking_number, attrs) do
    shipment = Repo.get_by!(Shipment, tracking_number: tracking_number)

    %TrackingEvent{}
    |> TrackingEvent.changeset(Map.put(attrs, :shipment_id, shipment.id))
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        update_shipment_status(shipment, event.status)
        {:ok, event}

      error ->
        error
    end
  end

  @doc """
  Syncs tracking events from the carrier API for a given shipment.
  Returns the number of new events inserted.
  """
  def sync_from_carrier(tracking_number) do
    shipment = Repo.get_by!(Shipment, tracking_number: tracking_number)

    case Carriers.fetch_events(shipment.carrier, tracking_number) do
      {:ok, remote_events} ->
        existing_ids = existing_external_ids(shipment.id)

        new_events =
          remote_events
          |> Enum.reject(&(&1.external_id in existing_ids))
          |> Enum.map(&build_event_attrs(shipment.id, &1))

        {count, _} = Repo.insert_all(TrackingEvent, new_events)

        Logger.info("Synced #{count} new events for #{tracking_number}")
        {:ok, count}

      {:error, reason} ->
        Logger.error("Carrier sync failed for #{tracking_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp latest_tracking_event(shipment_id) do
    TrackingEvent
    |> Repo.all_by(shipment_id: shipment_id)
    |> Enum.max_by(& &1.occurred_at, DateTime, fn -> nil end)
  end

  defp update_shipment_status(shipment, new_status) do
    shipment
    |> Shipment.changeset(%{status: new_status})
    |> Repo.update()
  end

  defp existing_external_ids(shipment_id) do
    TrackingEvent
    |> Repo.all_by(shipment_id: shipment_id)
    |> Enum.map(& &1.external_id)
    |> MapSet.new()
  end

  defp build_event_attrs(shipment_id, remote) do
    %{
      shipment_id: shipment_id,
      status: remote.status,
      location: remote.location,
      external_id: remote.external_id,
      occurred_at: remote.occurred_at,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
```
