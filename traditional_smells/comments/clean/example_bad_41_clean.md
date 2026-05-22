```elixir
defmodule ShipmentTracker do
  @moduledoc """
  Tracks parcel shipments across carriers, manages status transitions,
  and triggers downstream fulfilment events.
  """

  alias ShipmentTracker.{Carrier, Event, Parcel, ShipmentRepo}
  require Logger

  @valid_transitions %{
    pending: [:dispatched],
    dispatched: [:in_transit, :failed],
    in_transit: [:out_for_delivery, :failed],
    out_for_delivery: [:delivered, :failed],
    delivered: [],
    failed: [:pending]
  }

  @doc """
  Creates a new shipment record in the repository and assigns it a tracking number.
  """
  def create_shipment(%Parcel{} = parcel, carrier_code) when is_atom(carrier_code) do
    tracking_number = Carrier.generate_tracking_number(carrier_code, parcel)

    shipment = %{
      tracking_number: tracking_number,
      carrier: carrier_code,
      parcel: parcel,
      status: :pending,
      events: [],
      created_at: DateTime.utc_now()
    }

    ShipmentRepo.insert(shipment)
  end

  # Updates the status of a shipment identified by tracking_number.
  #
  # Parameters:
  #   tracking_number - binary, the shipment's carrier tracking reference
  #   new_status      - atom, the target status (must be a valid transition from current status)
  #   metadata        - map of additional event data, e.g. %{location: "LHR", note: "customs"}
  #
  # Valid status transitions are defined in @valid_transitions.
  # Emits an Event struct into the shipment's event log on success.
  # Returns {:ok, updated_shipment} or {:error, :invalid_transition | :not_found}.
  def update_shipment_status(tracking_number, new_status, metadata \\ %{})
      when is_binary(tracking_number) and is_atom(new_status) do
    with {:ok, shipment} <- ShipmentRepo.fetch(tracking_number),
         :ok <- validate_transition(shipment.status, new_status) do
      event = %Event{
        status: new_status,
        occurred_at: DateTime.utc_now(),
        metadata: metadata
      }

      updated =
        shipment
        |> Map.put(:status, new_status)
        |> Map.update!(:events, &[event | &1])

      ShipmentRepo.update(tracking_number, updated)
    end
  end

  @doc """
  Returns the full event history for a shipment in chronological order.
  """
  def event_history(tracking_number) when is_binary(tracking_number) do
    case ShipmentRepo.fetch(tracking_number) do
      {:ok, %{events: events}} -> {:ok, Enum.reverse(events)}
      {:error, :not_found} -> {:error, :shipment_not_found}
    end
  end

  @doc """
  Returns the latest event for a shipment.
  """
  def latest_event(tracking_number) when is_binary(tracking_number) do
    with {:ok, events} <- event_history(tracking_number) do
      case List.last(events) do
        nil -> {:error, :no_events}
        event -> {:ok, event}
      end
    end
  end

  @doc """
  Cancels a shipment if it has not yet been dispatched.
  """
  def cancel_shipment(tracking_number) when is_binary(tracking_number) do
    with {:ok, %{status: :pending}} <- ShipmentRepo.fetch(tracking_number) do
      ShipmentRepo.delete(tracking_number)
    else
      {:ok, %{status: status}} -> {:error, {:cannot_cancel, status}}
      error -> error
    end
  end

  defp validate_transition(current, next) do
    allowed = Map.get(@valid_transitions, current, [])

    if next in allowed do
      :ok
    else
      Logger.warning("Invalid transition: #{current} -> #{next}")
      {:error, :invalid_transition}
    end
  end
end
```
