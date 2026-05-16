```elixir
defmodule Logistics.ShipmentDispatcher do
  alias Logistics.{Repo, Shipment, Warehouse, Carrier, Route, AuditTrail}

  require Logger

  def dispatch_shipment(shipment_id, dispatcher_id) do
    with {:ok, shipment} <- fetch_pending_shipment(shipment_id),
         {:ok, warehouse} <- resolve_origin_warehouse(shipment),
         {:ok, route} <- Route.calculate(warehouse, shipment.destination),
         {:ok, carrier} <- Carrier.assign(route, shipment.weight_kg),
         {:ok, tracking} <- Carrier.create_label(carrier, shipment, route) do
      shipment
      |> Shipment.changeset(%{
        status: :dispatched,
        carrier_id: carrier.id,
        tracking_number: tracking.number,
        estimated_arrival: route.eta,
        dispatched_by: dispatcher_id,
        dispatched_at: DateTime.utc_now()
      })
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          AuditTrail.record(:shipment_dispatched, updated)
          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :not_found} ->
        Logger.error("Shipment #{shipment_id} not found")
        {:error, :shipment_not_found}

      {:error, :already_dispatched} ->
        Logger.warning("Shipment #{shipment_id} was already dispatched")
        {:error, :already_dispatched}

      {:error, :warehouse_inactive} ->
        Logger.error("Origin warehouse is inactive for shipment #{shipment_id}")
        {:error, :warehouse_unavailable}

      {:error, :no_route_available} ->
        Logger.error("No shipping route found for shipment #{shipment_id}")
        {:error, :routing_failure}

      {:error, :overweight} ->
        Logger.warning("No carrier accepts weight for shipment #{shipment_id}")
        {:error, :carrier_unavailable}

      {:error, :label_generation_failed} ->
        Logger.error("Carrier label generation failed for shipment #{shipment_id}")
        {:error, :carrier_error}

      {:error, reason} ->
        Logger.error("Unexpected dispatch error for #{shipment_id}: #{inspect(reason)}")
        {:error, :internal_error}
    end
  end

  defp fetch_pending_shipment(shipment_id) do
    case Repo.get(Shipment, shipment_id) do
      nil -> {:error, :not_found}
      %Shipment{status: :dispatched} -> {:error, :already_dispatched}
      shipment -> {:ok, shipment}
    end
  end

  defp resolve_origin_warehouse(%Shipment{warehouse_id: wid}) do
    case Repo.get(Warehouse, wid) do
      nil -> {:error, :not_found}
      %Warehouse{active: false} -> {:error, :warehouse_inactive}
      warehouse -> {:ok, warehouse}
    end
  end
end
```
