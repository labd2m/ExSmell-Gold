```elixir
defmodule MyApp.ShipmentTracker do
  @moduledoc """
  Tracks shipment lifecycle events, carrier status updates, and
  delivery confirmations for the MyApp logistics subsystem.
  """

  alias MyApp.Repo
  alias MyApp.Logistics.{Shipment, ShipmentEvent, DeliveryEstimate}
  alias MyApp.NotificationDispatcher

  require Logger

  @terminal_statuses [:delivered, :returned, :lost]

  @doc """
  Fetches a shipment by its tracking number.

  Returns `{:ok, %Shipment{}}` or `{:error, :not_found}`.
  """
  def fetch_by_tracking_number(tracking_number) do
    case Repo.get_by(Shipment, tracking_number: tracking_number) do
      nil -> {:error, :not_found}
      shipment -> {:ok, shipment}
    end
  end


  # update_shipment_status/3
  #
  # Records a new status transition for the given shipment.
  #
  # Parameters:
  #   shipment_id — integer primary key of the shipment
  #   new_status  — atom, one of: :processing, :picked_up, :in_transit,
  #                              :out_for_delivery, :delivered, :failed_attempt,
  #                              :returned, :lost
  #   metadata    — map of additional carrier-provided data (may be empty map)
  #
  # Behaviour:
  #   - If the shipment is already in a terminal status, the update is rejected.
  #   - A ShipmentEvent record is appended with the new status, timestamp, and metadata.
  #   - The parent Shipment's current_status and updated_at are refreshed.
  #   - On :delivered status, a delivery notification is dispatched to the recipient.
  #
  # Returns:
  #   {:ok, %Shipment{}}             — status updated successfully
  #   {:error, :shipment_not_found}  — no shipment with the given ID
  #   {:error, :terminal_status}     — shipment is already in a terminal state
  #   {:error, :invalid_status}      — new_status atom not in the allowed set
  def update_shipment_status(shipment_id, new_status, metadata \\ %{}) do
    with {:ok, shipment} <- load_shipment(shipment_id),
         :ok <- assert_not_terminal(shipment),
         :ok <- validate_status(new_status) do
      append_event(shipment, new_status, metadata)
      |> case do
        {:ok, updated_shipment} ->
          maybe_notify_delivery(updated_shipment, new_status)
          {:ok, updated_shipment}

        error ->
          error
      end
    end
  end

  @doc """
  Returns all events for a shipment in chronological order.
  """
  def event_history(shipment_id) do
    ShipmentEvent
    |> ShipmentEvent.for_shipment(shipment_id)
    |> ShipmentEvent.ordered_asc()
    |> Repo.all()
  end

  @doc """
  Updates the estimated delivery date for a shipment.
  Overwrites any existing estimate.
  """
  def set_delivery_estimate(shipment_id, estimated_date) do
    case Repo.get(Shipment, shipment_id) do
      nil ->
        {:error, :shipment_not_found}

      shipment ->
        upsert_estimate(shipment, estimated_date)
    end
  end

  # --- Private helpers ---

  defp load_shipment(shipment_id) do
    case Repo.get(Shipment, shipment_id) do
      nil -> {:error, :shipment_not_found}
      s -> {:ok, s}
    end
  end

  defp assert_not_terminal(%Shipment{current_status: status}) do
    if status in @terminal_statuses do
      {:error, :terminal_status}
    else
      :ok
    end
  end

  defp validate_status(status) do
    allowed = [
      :processing, :picked_up, :in_transit, :out_for_delivery,
      :delivered, :failed_attempt, :returned, :lost
    ]

    if status in allowed, do: :ok, else: {:error, :invalid_status}
  end

  defp append_event(shipment, new_status, metadata) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:event, ShipmentEvent.changeset(%ShipmentEvent{}, %{
      shipment_id: shipment.id,
      status: new_status,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }))
    |> Ecto.Multi.update(:shipment, Shipment.changeset(shipment, %{current_status: new_status}))
    |> Repo.transaction()
    |> case do
      {:ok, %{shipment: s}} -> {:ok, s}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp maybe_notify_delivery(%Shipment{} = shipment, :delivered) do
    notification = %{
      type: :shipment_delivered,
      subject: "Your shipment has been delivered!",
      body: "Tracking ##{shipment.tracking_number} was delivered successfully.",
      metadata: %{shipment_id: shipment.id}
    }

    recipient = Repo.get!(MyApp.Accounts.User, shipment.recipient_user_id)
    NotificationDispatcher.dispatch(recipient, notification)
  end

  defp maybe_notify_delivery(_shipment, _status), do: :noop

  defp upsert_estimate(shipment, estimated_date) do
    params = %{shipment_id: shipment.id, estimated_date: estimated_date}

    case Repo.get_by(DeliveryEstimate, shipment_id: shipment.id) do
      nil ->
        %DeliveryEstimate{}
        |> DeliveryEstimate.changeset(params)
        |> Repo.insert()

      existing ->
        existing
        |> DeliveryEstimate.changeset(params)
        |> Repo.update()
    end
  end
end
```
