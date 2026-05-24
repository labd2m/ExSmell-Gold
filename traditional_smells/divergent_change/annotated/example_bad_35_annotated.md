# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `ShipmentCoordinator` module (entire module)
- **Affected functions:** `book_shipment/3`, `update_tracking_status/2`, `estimate_cost/3`, `select_carrier/2`, `generate_shipping_label/2`
- **Explanation:** `ShipmentCoordinator` mixes shipment booking, real-time tracking updates, rate estimation/carrier selection, and label generation. These represent different logistics concerns — carrier APIs change, tracking event schemas change, rate calculation algorithms change, and label format specs change — each causing unrelated edits to one module.

---

```elixir
defmodule MyApp.ShipmentCoordinator do
  @moduledoc """
  Coordinates shipment booking, tracking status updates, freight rate
  estimation, carrier selection, and label generation.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Shipment, TrackingEvent}
  alias MyApp.Carriers.{FedEx, UPS, USPS}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module bundles shipment booking,
  # tracking updates, rate estimation, carrier selection, and label generation.
  # Each is independently driven to change — new carriers, tracking event
  # schemas, rate table updates, or label format changes each force unrelated
  # modifications to this single module.

  ## ── Shipment Booking ─────────────────────────────────────────────────────────

  @doc """
  Books a shipment with the best available carrier for the given package.
  """
  def book_shipment(order_id, origin, destination) do
    package = MyApp.Orders.build_package(order_id)
    carrier = select_carrier(package, destination)
    rate_cents = estimate_cost(carrier, package, destination)

    with {:ok, booking} <- dispatch_booking(carrier, origin, destination, package) do
      %Shipment{}
      |> Shipment.changeset(%{
        order_id: order_id,
        carrier: carrier,
        tracking_number: booking.tracking_number,
        rate_cents: rate_cents,
        origin: origin,
        destination: destination,
        status: :booked,
        estimated_delivery: booking.estimated_delivery,
        booked_at: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  defp dispatch_booking(:fedex, origin, dest, pkg), do: FedEx.create_shipment(origin, dest, pkg)
  defp dispatch_booking(:ups, origin, dest, pkg), do: UPS.create_shipment(origin, dest, pkg)
  defp dispatch_booking(:usps, origin, dest, pkg), do: USPS.create_shipment(origin, dest, pkg)

  ## ── Tracking Status ──────────────────────────────────────────────────────────

  @doc """
  Ingests a tracking event from a carrier webhook and updates shipment status.
  """
  def update_tracking_status(%Shipment{} = shipment, event_data) do
    status = normalize_carrier_status(shipment.carrier, event_data["status"])

    Repo.transaction(fn ->
      %TrackingEvent{}
      |> TrackingEvent.changeset(%{
        shipment_id: shipment.id,
        raw_status: event_data["status"],
        normalized_status: status,
        location: event_data["location"],
        occurred_at: parse_carrier_datetime(event_data["timestamp"])
      })
      |> Repo.insert!()

      shipment
      |> Shipment.changeset(%{status: status, last_event_at: DateTime.utc_now()})
      |> Repo.update!()
    end)
  end

  defp normalize_carrier_status(:fedex, "OC"), do: :in_transit
  defp normalize_carrier_status(:fedex, "DL"), do: :delivered
  defp normalize_carrier_status(:ups, "I"), do: :in_transit
  defp normalize_carrier_status(:ups, "D"), do: :delivered
  defp normalize_carrier_status(_, _), do: :unknown

  defp parse_carrier_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  ## ── Rate Estimation ──────────────────────────────────────────────────────────

  @doc """
  Estimates the shipping cost in cents for a carrier and package.
  """
  def estimate_cost(carrier, %{weight_grams: weight, dimensions: dims}, destination) do
    base =
      case carrier do
        :fedex -> 599
        :ups -> 649
        :usps -> 449
      end

    volume_cc = dims.length_cm * dims.width_cm * dims.height_cm
    dimensional_weight = volume_cc / 5_000.0
    billable_weight = max(weight / 1000.0, dimensional_weight)

    zone_surcharge =
      case destination.country do
        "US" -> 0
        "CA" -> 300
        _ -> 800
      end

    round(base + billable_weight * 80 + zone_surcharge)
  end

  @doc """
  Selects the most cost-effective carrier for a package and destination.
  """
  def select_carrier(package, destination) do
    carriers = [:fedex, :ups, :usps]

    Enum.min_by(carriers, fn c ->
      estimate_cost(c, package, destination)
    end)
  end

  ## ── Label Generation ─────────────────────────────────────────────────────────

  @doc """
  Generates a shipping label PDF for an existing booked shipment.
  """
  def generate_shipping_label(%Shipment{} = shipment) do
    case shipment.carrier do
      :fedex -> FedEx.fetch_label(shipment.tracking_number)
      :ups -> UPS.fetch_label(shipment.tracking_number)
      :usps -> USPS.fetch_label(shipment.tracking_number)
    end
    |> case do
      {:ok, label_bytes} ->
        key = "labels/#{shipment.tracking_number}.pdf"
        MyApp.Storage.put_object(key, label_bytes)
        {:ok, MyApp.Storage.public_url(key)}

      error ->
        error
    end
  end

  # VALIDATION: SMELL END
end
```
