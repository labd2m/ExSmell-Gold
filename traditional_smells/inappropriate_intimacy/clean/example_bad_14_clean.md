```elixir
defmodule MyApp.Logistics.ShipmentRouter do
  @moduledoc """
  Selects the optimal carrier and service level for outbound shipments
  based on package characteristics, destination, and carrier capabilities.
  """

  alias MyApp.Logistics.{Carrier, Package, ShipmentRecord}
  alias MyApp.Geo.Zone
  alias MyApp.Notifications.ShipmentMailer

  @carriers [:fedex, :ups, :dhl, :usps]

  def route(package_id, destination_address) do
    with {:ok, package} <- Package.fetch(package_id),
         {:ok, zone}    <- Zone.for_address(destination_address) do

      weight        = package.actual_weight_kg
      declared_val  = package.declared_value
      is_fragile    = package.fragile

      now = DateTime.utc_now()

      eligible =
        Enum.reduce(@carriers, [], fn carrier_id, acc ->
          carrier = Carrier.find(carrier_id)
          zone_ok     = zone.id in carrier.supported_zones
          weight_ok   = weight <= carrier.max_weight_kg
          express_ok  = DateTime.compare(now, carrier.express_cutoff) == :lt

          if zone_ok and weight_ok do
            service = if express_ok, do: :express, else: :standard
            [{carrier, service} | acc]
          else
            acc
          end
        end)

      case choose_best(eligible, is_fragile, declared_val) do
        nil ->
          {:error, :no_carrier_available}

        {carrier, service} ->
          create_shipment(package, carrier, service, destination_address, zone)
      end
    end
  end

  def track(shipment_id) do
    case ShipmentRecord.fetch(shipment_id) do
      nil      -> {:error, :not_found}
      shipment -> Carrier.track(shipment.carrier_id, shipment.tracking_number)
    end
  end

  def cancel(shipment_id) do
    case ShipmentRecord.fetch(shipment_id) do
      nil -> {:error, :not_found}
      %{status: :delivered} -> {:error, :already_delivered}
      shipment ->
        Carrier.cancel_pickup(shipment.carrier_id, shipment.tracking_number)
        updated = %{shipment | status: :cancelled, cancelled_at: DateTime.utc_now()}
        ShipmentRecord.save(updated)
        {:ok, updated}
    end
  end

  def list_for_order(order_id) do
    :ets.tab2list(:shipments)
    |> Enum.map(fn {_, s} -> s end)
    |> Enum.filter(&(&1.order_id == order_id))
    |> Enum.sort_by(& &1.created_at)
  end


  defp choose_best([], _fragile, _val), do: nil

  defp choose_best(candidates, fragile, declared_val) do
    candidates
    |> Enum.filter(fn {carrier, _} ->
      not fragile or Carrier.handles_fragile?(carrier.id)
    end)
    |> Enum.filter(fn {carrier, _} ->
      declared_val <= Carrier.max_insurable_value(carrier.id)
    end)
    |> Enum.min_by(fn {carrier, service} ->
      Carrier.rate_quote(carrier.id, service)
    end, fn -> nil end)
  end

  defp create_shipment(package, carrier, service, destination, zone) do
    {:ok, tracking} = Carrier.book_pickup(carrier.id, package.id)
    shipment = %{
      id:              generate_id(),
      package_id:      package.id,
      carrier_id:      carrier.id,
      service:         service,
      zone_id:         zone.id,
      destination:     destination,
      tracking_number: tracking,
      status:          :booked,
      created_at:      DateTime.utc_now()
    }
    ShipmentRecord.save(shipment)
    ShipmentMailer.deliver_confirmation(shipment)
    {:ok, shipment}
  end

  defp generate_id do
    "SHP-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
