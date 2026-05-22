# Annotated Example — Code Smell: Comments

| Field | Value |
|---|---|
| **Smell name** | Comments |
| **Expected smell location** | `ShipmentTracker.record_checkpoint/2` |
| **Affected function(s)** | `record_checkpoint/2` |
| **Short explanation** | `record_checkpoint/2` uses plain `#` comment lines as its documentation rather than an `@doc` attribute, which means the documentation is invisible to ExDoc and IEx tooling. |

```elixir
defmodule MyApp.ShipmentTracker do
  @moduledoc """
  Tracks parcel movements through the logistics network by recording
  checkpoint events and computing estimated delivery windows.
  """

  import Ecto.Query
  alias MyApp.{Repo, Shipment, Checkpoint, Carrier, DeliveryEstimate}
  alias MyApp.Notifications.ShipmentNotifier
  require Logger

  @final_statuses [:delivered, :returned, :lost]
  @delivery_window_hours 48

  @doc """
  Looks up the current status and latest checkpoint for a shipment.

  Returns `{:ok, shipment}` with preloaded checkpoints, or
  `{:error, :not_found}` if no shipment exists for the given tracking number.
  """
  def track(tracking_number) do
    case Repo.one(
           from(s in Shipment,
             where: s.tracking_number == ^tracking_number,
             preload: [:checkpoints, :carrier]
           )
         ) do
      nil -> {:error, :not_found}
      shipment -> {:ok, shipment}
    end
  end

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because the developer chose to describe
  # VALIDATION: `record_checkpoint/2` using a block of `#` comment lines
  # VALIDATION: rather than the `@doc` attribute. The documentation will
  # VALIDATION: not appear in ExDoc output or IEx `h/1` introspection.

  # record_checkpoint/2
  #
  # Appends a new location checkpoint to a shipment's tracking history.
  #
  # Parameters:
  #   shipment_id  - integer ID of the shipment
  #   event        - map describing the checkpoint event with keys:
  #                    :location     - string, human-readable location name
  #                    :status       - atom, e.g. :in_transit, :out_for_delivery, :delivered
  #                    :occurred_at  - DateTime of the scan event
  #                    :notes        - optional string
  #
  # Side effects:
  #   - Updates shipment.current_status to the new status.
  #   - If status is :delivered, sets shipment.delivered_at.
  #   - Sends a push/email notification to the recipient via ShipmentNotifier.
  #   - If the status is one of @final_statuses, closes the shipment.
  #
  # Returns {:ok, checkpoint} or {:error, reason}.

  # VALIDATION: SMELL END
  def record_checkpoint(shipment_id, %{status: status} = event) do
    Repo.transaction(fn ->
      case Repo.get(Shipment, shipment_id) do
        nil ->
          Repo.rollback(:shipment_not_found)

        shipment when shipment.current_status in @final_statuses ->
          Repo.rollback(:shipment_already_closed)

        shipment ->
          {:ok, checkpoint} =
            %Checkpoint{}
            |> Checkpoint.changeset(%{
              shipment_id: shipment.id,
              location: Map.get(event, :location),
              status: status,
              notes: Map.get(event, :notes),
              occurred_at: Map.get(event, :occurred_at, DateTime.utc_now())
            })
            |> Repo.insert()

          shipment_updates =
            build_shipment_updates(status, event)

          shipment
          |> Shipment.changeset(shipment_updates)
          |> Repo.update!()

          ShipmentNotifier.notify_status_change(shipment.recipient_id, shipment, checkpoint)

          Logger.info(
            "[Tracker] Checkpoint recorded for shipment #{shipment_id}: #{status} @ #{Map.get(event, :location)}"
          )

          checkpoint
      end
    end)
    |> case do
      {:ok, checkpoint} -> {:ok, checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the estimated delivery window for a shipment.

  Queries the carrier's expected transit times and adds the delivery window buffer.
  Returns `{:ok, %{earliest: DateTime.t(), latest: DateTime.t()}}` or
  `{:error, :no_estimate_available}`.
  """
  def estimated_delivery(shipment_id) do
    case Repo.get(Shipment, shipment_id) do
      nil ->
        {:error, :shipment_not_found}

      %Shipment{current_status: status} when status in @final_statuses ->
        {:error, :already_closed}

      shipment ->
        case Repo.get_by(DeliveryEstimate, shipment_id: shipment.id) do
          nil ->
            {:error, :no_estimate_available}

          estimate ->
            {:ok,
             %{
               earliest: estimate.expected_at,
               latest: DateTime.add(estimate.expected_at, @delivery_window_hours * 3600, :second)
             }}
        end
    end
  end

  ## Private

  defp build_shipment_updates(:delivered, event) do
    %{
      current_status: :delivered,
      delivered_at: Map.get(event, :occurred_at, DateTime.utc_now()),
      closed_at: DateTime.utc_now()
    }
  end

  defp build_shipment_updates(status, _event) when status in @final_statuses do
    %{current_status: status, closed_at: DateTime.utc_now()}
  end

  defp build_shipment_updates(status, _event) do
    %{current_status: status}
  end
end
```
