```elixir
defmodule ShipmentCoordinator do
  @moduledoc """
  Handles all logistics operations from shipment creation through delivery.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Logistics.{Shipment, Route, CarrierRate, CustomsDocument, TrackingEvent}
  alias MyApp.Carriers.{FedExClient, DHLClient, UPSClient}

  @carriers [:fedex, :dhl, :ups]
  @max_domestic_weight_kg 30
  @express_threshold_days 2


  def create_shipment(attrs) do
    with {:ok, validated} <- validate_address(attrs.destination),
         {:ok, shipment} <- Repo.insert(Shipment.changeset(%Shipment{}, attrs)) do
      Logger.info("Shipment #{shipment.id} created for order #{attrs.order_id}")
      {:ok, shipment}
    end
  end

  defp validate_address(%{country: c, postal_code: pc}) when byte_size(pc) > 0 and byte_size(c) == 2,
    do: {:ok, :valid}
  defp validate_address(_), do: {:error, :invalid_address}


  def plan_route(%Shipment{origin: origin, destination: destination, weight_kg: w}) do
    hubs = intermediate_hubs(origin, destination)

    route = %Route{
      legs: hubs,
      estimated_days: estimate_transit_days(hubs, w),
      distance_km: calculate_distance(origin, destination)
    }

    {:ok, route}
  end

  defp intermediate_hubs(origin, destination) do
    cond do
      same_region?(origin, destination) -> [origin, destination]
      cross_continent?(origin, destination) -> [origin, hub_for(origin), hub_for(destination), destination]
      true -> [origin, hub_for(origin), destination]
    end
  end

  defp same_region?(%{region: r}, %{region: r}), do: true
  defp same_region?(_, _), do: false

  defp cross_continent?(%{continent: a}, %{continent: b}), do: a != b

  defp hub_for(%{region: region}), do: "HUB-#{String.upcase(region)}"

  defp estimate_transit_days(legs, w) when w > @max_domestic_weight_kg, do: length(legs) + 2
  defp estimate_transit_days(legs, _), do: length(legs)

  defp calculate_distance(_origin, _destination), do: :rand.uniform(5000) + 100


  def select_carrier(%Shipment{} = shipment, preferences \\ %{}) do
    rates = fetch_all_rates(shipment)

    selected =
      cond do
        preferences[:priority] == :cheapest ->
          Enum.min_by(rates, & &1.price)

        preferences[:priority] == :fastest ->
          Enum.min_by(rates, & &1.estimated_days)

        shipment.weight_kg > 20 ->
          Enum.find(rates, &(&1.carrier == :dhl)) || Enum.min_by(rates, & &1.price)

        true ->
          Enum.min_by(rates, &(&1.price * 0.7 + &1.estimated_days * 10))
      end

    Logger.debug("Carrier #{selected.carrier} selected at #{selected.price}")
    {:ok, selected}
  end

  defp fetch_all_rates(%Shipment{} = s) do
    @carriers
    |> Enum.map(fn carrier -> fetch_rate(carrier, s) end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_rate(:fedex, s), do: FedExClient.get_rate(s)
  defp fetch_rate(:dhl, s), do: DHLClient.get_rate(s)
  defp fetch_rate(:ups, s), do: UPSClient.get_rate(s)


  def generate_customs_doc(%Shipment{destination: %{country: country}} = shipment)
      when country not in ["BR", "US", "DE"] do
    doc = %CustomsDocument{
      shipment_id: shipment.id,
      declared_value: shipment.declared_value,
      commodity_code: shipment.commodity_code,
      description: shipment.description,
      country_of_origin: shipment.origin.country,
      generated_at: DateTime.utc_now()
    }

    case Repo.insert(doc) do
      {:ok, d} -> {:ok, d}
      {:error, cs} -> {:error, cs}
    end
  end

  def generate_customs_doc(_shipment), do: {:ok, :not_required}


  def generate_label(%Shipment{id: id, carrier: carrier, tracking_number: tn}) do
    label_content = """
    SHIPMENT: #{id}
    CARRIER: #{carrier}
    TRACKING: #{tn}
    GENERATED: #{DateTime.utc_now()}
    """

    path = "/var/labels/#{id}.zpl"
    File.write(path, label_content)
    {:ok, path}
  end


  def record_tracking_event(shipment_id, status, location, timestamp \\ DateTime.utc_now()) do
    %TrackingEvent{
      shipment_id: shipment_id,
      status: status,
      location: location,
      occurred_at: timestamp
    }
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        Logger.info("Tracking event #{status} for shipment #{shipment_id}")
        {:ok, event}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def get_tracking_history(shipment_id) do
    Repo.all(
      from e in TrackingEvent,
        where: e.shipment_id == ^shipment_id,
        order_by: [asc: e.occurred_at]
    )
  end


  def confirm_delivery(shipment_id, %{signed_by: name, photo_url: url, delivered_at: ts}) do
    shipment = Repo.get!(Shipment, shipment_id)

    shipment
    |> Shipment.changeset(%{
      status: :delivered,
      signed_by: name,
      delivery_photo_url: url,
      delivered_at: ts
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        record_tracking_event(shipment_id, :delivered, shipment.destination, ts)
        {:ok, updated}

      err ->
        err
    end
  end

  def is_express?(%Shipment{} = shipment) do
    case plan_route(shipment) do
      {:ok, %Route{estimated_days: d}} -> d <= @express_threshold_days
      _ -> false
    end
  end
end
```
