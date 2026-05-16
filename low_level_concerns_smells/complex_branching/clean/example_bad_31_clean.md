# Example 31

```elixir
defmodule Logistics.CarrierSync do
  @moduledoc """
  Synchronises shipment tracking data from carrier APIs into the local database.
  Runs on a periodic schedule via Oban workers.
  """

  require Logger

  alias Logistics.Repo
  alias Logistics.Schema.Shipment
  alias Logistics.Carrier.Client
  alias Logistics.Notifications

  @terminal_statuses [:delivered, :returned_to_sender, :lost]

  def run_sync_batch(shipment_ids) when is_list(shipment_ids) do
    shipment_ids
    |> Enum.map(&sync_one/1)
    |> Enum.group_by(fn
      {:ok, _} -> :ok
      {:error, _} -> :error
    end)
  end

  defp sync_one(shipment_id) do
    case Repo.get(Shipment, shipment_id) do
      nil ->
        Logger.warning("Shipment #{shipment_id} not found, skipping sync")
        {:error, :not_found}

      %Shipment{status: status} = shipment when status in @terminal_statuses ->
        Logger.debug("Shipment #{shipment_id} already in terminal status #{status}, skipping")
        {:ok, :skipped}

      shipment ->
        sync_shipment_status(shipment, Client.get_tracking(shipment.tracking_number))
    end
  end

  defp sync_shipment_status(shipment, carrier_response) do
    case carrier_response do
      {:ok, %{status: 200, body: %{"tracking_status" => "in_transit", "eta" => eta, "location" => loc}}} ->
        Logger.info("Shipment #{shipment.id} in transit, ETA #{eta}, location: #{loc}")

        shipment
        |> Shipment.changeset(%{status: :in_transit, estimated_arrival: eta, last_location: loc})
        |> Repo.update()

      {:ok, %{status: 200, body: %{"tracking_status" => "out_for_delivery", "location" => loc}}} ->
        Logger.info("Shipment #{shipment.id} out for delivery at #{loc}")

        result =
          shipment
          |> Shipment.changeset(%{status: :out_for_delivery, last_location: loc})
          |> Repo.update()

        Notifications.send_out_for_delivery(shipment)
        result

      {:ok, %{status: 200, body: %{"tracking_status" => "delivered", "delivered_at" => ts}}} ->
        Logger.info("Shipment #{shipment.id} delivered at #{ts}")

        result =
          shipment
          |> Shipment.changeset(%{status: :delivered, delivered_at: ts})
          |> Repo.update()

        Notifications.send_delivery_confirmation(shipment)
        result

      {:ok, %{status: 200, body: %{"tracking_status" => "returned_to_sender", "reason" => reason}}} ->
        Logger.warning("Shipment #{shipment.id} returned to sender: #{reason}")

        shipment
        |> Shipment.changeset(%{status: :returned_to_sender, return_reason: reason})
        |> Repo.update()

      {:ok, %{status: 200, body: %{"tracking_status" => "held_at_customs", "customs_ref" => ref}}} ->
        Logger.warning("Shipment #{shipment.id} held at customs, ref #{ref}")

        shipment
        |> Shipment.changeset(%{status: :held_at_customs, customs_reference: ref})
        |> Repo.update()

      {:ok, %{status: 200, body: %{"tracking_status" => "lost"}}} ->
        Logger.error("Shipment #{shipment.id} reported lost by carrier")

        result =
          shipment
          |> Shipment.changeset(%{status: :lost})
          |> Repo.update()

        Notifications.send_loss_alert(shipment)
        result

      {:ok, %{status: 200, body: %{"tracking_status" => unknown}}} ->
        Logger.warning("Unknown tracking status '#{unknown}' for shipment #{shipment.id}")
        {:error, {:unknown_status, unknown}}

      {:ok, %{status: 404}} ->
        Logger.warning("Tracking number not found for shipment #{shipment.id}")
        {:error, :tracking_not_found}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by carrier API for shipment #{shipment.id}")
        {:error, :rate_limited}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("Carrier API unavailable for shipment #{shipment.id}")
        {:error, :carrier_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected carrier response #{status} for shipment #{shipment.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("Carrier API timeout for shipment #{shipment.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Carrier API error for shipment #{shipment.id}: #{inspect(reason)}")
        {:error, {:carrier_error, reason}}
    end
  end

  def resync_failed(since \\ DateTime.utc_now() |> DateTime.add(-86_400)) do
    Shipment
    |> Shipment.failed_since(since)
    |> Repo.all()
    |> Enum.map(& &1.id)
    |> run_sync_batch()
  end
end
```
