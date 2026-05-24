```elixir
defmodule Logistics.ShipmentDispatcher do
  @moduledoc """
  Dispatches outbound shipments by selecting an appropriate carrier and
  service level based on package characteristics and destination zone.
  """

  require Logger

  alias Logistics.{Carrier, Package, Shipment, Route}
  alias Logistics.Tracking
  alias Repo

  @max_dispatch_retries 3

  def dispatch(package_id, destination_address) do
    with {:ok, package} <- Package.fetch(package_id),
         {:ok, zone} <- Route.resolve_zone(destination_address),
         {:ok, carriers} <- Carrier.list_active() do
      case choose_carrier(package, zone, carriers) do
        {:ok, carrier, service} ->
          create_shipment(package, carrier, service, destination_address, zone)

        {:error, reason} ->
          Logger.warning("No suitable carrier for package #{package_id}: #{reason}")
          {:error, :no_carrier_available}
      end
    end
  end

  defp choose_carrier(package, zone, carriers) do
    eligible =
      Enum.filter(carriers, fn carrier ->
        carrier.active &&
          carrier.max_weight_kg >= package.weight_kg &&
          zone in carrier.supported_zones &&
          fits_volume_limit?(package.dimensions, carrier.max_volume_cm3) &&
          (not package.fragile or carrier.handles_fragile)
      end)

    case eligible do
      [] ->
        {:error, :no_eligible_carrier}

      [carrier | _] ->
        service = select_service_level(package, carrier)
        {:ok, carrier, service}
    end
  end

  defp select_service_level(package, carrier) do
    current_hour = DateTime.utc_now().hour

    cond do
      package.weight_kg < 0.5 and carrier.express_available ->
        :express

      carrier.overnight_cutoff_hour != nil and
          current_hour < carrier.overnight_cutoff_hour and
          not package.fragile ->
        :overnight

      true ->
        :standard
    end
  end

  defp fits_volume_limit?(dimensions, max_volume) do
    %{length_cm: l, width_cm: w, height_cm: h} = dimensions
    l * w * h <= max_volume
  end

  defp create_shipment(package, carrier, service, address, zone) do
    tracking_number = Tracking.generate_number(carrier.code)

    shipment = %Shipment{
      package_id: package.id,
      carrier_id: carrier.id,
      service_level: service,
      destination_address: address,
      zone: zone,
      tracking_number: tracking_number,
      estimated_delivery_days: delivery_days(service),
      dispatched_at: DateTime.utc_now(),
      status: :dispatched
    }

    case Repo.insert(shipment) do
      {:ok, saved} ->
        Logger.info("Shipment #{saved.id} dispatched via #{carrier.name} (#{service})")
        {:ok, saved}

      {:error, changeset} ->
        Logger.error("Failed to persist shipment: #{inspect(changeset.errors)}")
        {:error, :persistence_failed}
    end
  end

  defp delivery_days(:express), do: 1
  defp delivery_days(:overnight), do: 1
  defp delivery_days(:standard), do: 5

  def cancel_shipment(%Shipment{status: :dispatched} = shipment) do
    with {:ok, _} <- Carrier.request_cancellation(shipment.carrier_id, shipment.tracking_number) do
      shipment
      |> Shipment.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  def cancel_shipment(%Shipment{}), do: {:error, :not_cancellable}
end
```
