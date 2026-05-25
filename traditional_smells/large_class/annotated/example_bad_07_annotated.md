# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `ShipmentManager` module
- **Affected function(s):** `create_shipment/2`, `book_with_carrier/2`, `update_tracking/2`, `mark_delivered/1`, `mark_failed/2`, `calculate_shipping_rate/2`, `validate_address/1`, `normalize_address/1`, `schedule_pickup/2`, `generate_label/1`, `shipment_report/2`
- **Short explanation:** `ShipmentManager` merges shipment creation, carrier booking, tracking updates, delivery outcomes, rate calculation, address validation/normalization, pickup scheduling, label generation, and reporting. These are distinct logistics sub-domains that should be split into focused modules (e.g., `CarrierClient`, `AddressValidator`, `ShippingRates`, `LabelService`, `ShipmentTracker`).

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because ShipmentManager handles carrier API
# integration, address validation, rate calculation, label generation, tracking
# updates, pickup scheduling, and reporting — at least six unrelated logistics
# concerns fused into one oversized module.
defmodule MyApp.ShipmentManager do
  @moduledoc """
  Manages the full shipment lifecycle: carrier booking, tracking,
  label generation, address validation, rate shopping, and reporting.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Logistics.{Shipment, ShipmentEvent, PickupRequest}
  alias MyApp.Orders.Order

  @carriers    [:fedex, :ups, :dhl, :usps]
  @label_dpi   300

  # -------------------------------------------------------------------
  # Shipment creation
  # -------------------------------------------------------------------

  def create_shipment(%Order{} = order, opts \\ []) do
    carrier     = opts[:carrier] || :fedex
    service     = opts[:service] || :ground
    origin      = opts[:origin]  || MyApp.Config.warehouse_address()

    {:ok, norm_dest} = normalize_address(order.shipping_address)

    case validate_address(norm_dest) do
      {:ok, valid_address} ->
        rate = calculate_shipping_rate(origin, valid_address, %{
          weight_oz: order.total_weight_oz,
          carrier:   carrier,
          service:   service
        })

        shipment = Repo.insert!(%Shipment{
          order_id:         order.id,
          origin_address:   origin,
          destination:      valid_address,
          carrier:          carrier,
          service:          service,
          rate_cents:       rate,
          status:           :created
        })

        {:ok, shipment}

      {:error, reason} ->
        {:error, {:invalid_address, reason}}
    end
  end

  # -------------------------------------------------------------------
  # Carrier booking
  # -------------------------------------------------------------------

  def book_with_carrier(%Shipment{status: :created} = shipment, opts \\ []) do
    carrier_module = carrier_module_for(shipment.carrier)

    result = carrier_module.book(%{
      origin:      shipment.origin_address,
      destination: shipment.destination,
      weight_oz:   opts[:weight_oz],
      service:     shipment.service,
      reference:   "ORDER-#{shipment.order_id}"
    })

    case result do
      {:ok, booking} ->
        updated = Repo.update!(Shipment.changeset(shipment, %{
          status:          :booked,
          carrier_booking_id: booking.id,
          estimated_delivery: booking.estimated_delivery
        }))

        {:ok, label_url} = generate_label(updated)
        Repo.update!(Shipment.changeset(updated, %{label_url: label_url}))

        record_event(shipment.id, :booked, %{carrier_booking_id: booking.id})
        {:ok, updated}

      {:error, reason} ->
        record_event(shipment.id, :booking_failed, %{reason: reason})
        {:error, reason}
    end
  end

  def book_with_carrier(%Shipment{status: s}, _),
    do: {:error, "Cannot book shipment in status #{s}"}

  # -------------------------------------------------------------------
  # Tracking updates
  # -------------------------------------------------------------------

  def update_tracking(%Shipment{} = shipment, tracking_event) do
    Repo.update!(Shipment.changeset(shipment, %{
      tracking_number:  tracking_event[:tracking_number] || shipment.tracking_number,
      last_location:    tracking_event[:location],
      last_tracked_at:  DateTime.utc_now()
    }))

    record_event(shipment.id, :tracking_update, tracking_event)
    :ok
  end

  def mark_delivered(%Shipment{} = shipment) do
    Repo.update!(Shipment.changeset(shipment, %{
      status:       :delivered,
      delivered_at: DateTime.utc_now()
    }))

    record_event(shipment.id, :delivered, %{})
    MyApp.OrderManager.notify_status_change(Repo.get!(Order, shipment.order_id), :delivered)
    :ok
  end

  def mark_failed(%Shipment{} = shipment, reason) do
    Repo.update!(Shipment.changeset(shipment, %{
      status:        :failed,
      failure_reason: reason
    }))

    record_event(shipment.id, :failed, %{reason: reason})
    :ok
  end

  defp record_event(shipment_id, event_type, metadata) do
    Repo.insert!(%ShipmentEvent{
      shipment_id: shipment_id,
      event_type:  event_type,
      metadata:    metadata,
      occurred_at: DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Rate calculation
  # -------------------------------------------------------------------

  def calculate_shipping_rate(origin, destination, params) do
    base  = base_rate_for(params[:carrier], params[:service])
    zones = zone_multiplier(origin[:zip], destination[:zip])

    weight_factor =
      cond do
        params[:weight_oz] > 160 -> 3.0
        params[:weight_oz] > 80  -> 2.0
        params[:weight_oz] > 32  -> 1.5
        true                     -> 1.0
      end

    round(base * zones * weight_factor)
  end

  defp base_rate_for(:fedex, :ground),    do: 599
  defp base_rate_for(:fedex, :overnight), do: 2999
  defp base_rate_for(:ups, :ground),      do: 549
  defp base_rate_for(:ups, :overnight),   do: 2799
  defp base_rate_for(:usps, :priority),   do: 899
  defp base_rate_for(:dhl, :express),     do: 3299
  defp base_rate_for(_, _),               do: 1000

  defp zone_multiplier(from_zip, to_zip) do
    diff = abs(String.to_integer(String.slice(from_zip, 0, 3)) -
               String.to_integer(String.slice(to_zip, 0, 3)))

    cond do
      diff < 50  -> 1.0
      diff < 200 -> 1.3
      diff < 500 -> 1.6
      true       -> 2.0
    end
  end

  # -------------------------------------------------------------------
  # Address validation and normalization
  # -------------------------------------------------------------------

  def validate_address(addr) do
    required = [:street, :city, :state, :zip, :country]
    missing  = Enum.filter(required, &is_nil(Map.get(addr, &1)))

    if Enum.empty?(missing) do
      case MyApp.AddressVerifier.verify(addr) do
        {:ok, verified}  -> {:ok, verified}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  def normalize_address(addr) when is_map(addr) do
    normalized = %{
      street:  String.upcase(addr[:street] || ""),
      city:    String.upcase(addr[:city]   || ""),
      state:   String.upcase(addr[:state]  || ""),
      zip:     String.replace(addr[:zip]   || "", ~r/\s+/, ""),
      country: String.upcase(addr[:country] || "US")
    }

    {:ok, normalized}
  end

  # -------------------------------------------------------------------
  # Pickup scheduling
  # -------------------------------------------------------------------

  def schedule_pickup(%Shipment{} = shipment, pickup_date) do
    carrier_module = carrier_module_for(shipment.carrier)

    case carrier_module.request_pickup(%{
           booking_id:  shipment.carrier_booking_id,
           pickup_date: pickup_date,
           address:     shipment.origin_address
         }) do
      {:ok, confirmation} ->
        Repo.insert!(%PickupRequest{
          shipment_id:      shipment.id,
          scheduled_date:   pickup_date,
          confirmation_code: confirmation.code,
          status:            :scheduled
        })
        {:ok, confirmation}

      {:error, _} = err ->
        err
    end
  end

  # -------------------------------------------------------------------
  # Label generation
  # -------------------------------------------------------------------

  def generate_label(%Shipment{carrier_booking_id: booking_id} = shipment) when not is_nil(booking_id) do
    carrier_module = carrier_module_for(shipment.carrier)

    case carrier_module.fetch_label(booking_id, dpi: @label_dpi, format: :pdf) do
      {:ok, label_data} ->
        path = "/tmp/labels/#{shipment.id}.pdf"
        File.write!(path, label_data)
        {:ok, path}

      {:error, _} = err ->
        err
    end
  end

  def generate_label(_), do: {:error, :no_booking}

  # -------------------------------------------------------------------
  # Reporting
  # -------------------------------------------------------------------

  def shipment_report(start_date, end_date) do
    from(s in Shipment,
      where: s.inserted_at >= ^start_date and s.inserted_at <= ^end_date
    )
    |> Repo.all()
    |> Enum.group_by(& &1.carrier)
    |> Map.new(fn {carrier, shipments} ->
      delivered = Enum.count(shipments, &(&1.status == :delivered))
      failed    = Enum.count(shipments, &(&1.status == :failed))
      total_rev = Enum.sum(Enum.map(shipments, & &1.rate_cents))

      {carrier, %{total: length(shipments), delivered: delivered, failed: failed, revenue_cents: total_rev}}
    end)
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp carrier_module_for(:fedex), do: MyApp.Carriers.FedEx
  defp carrier_module_for(:ups),   do: MyApp.Carriers.UPS
  defp carrier_module_for(:dhl),   do: MyApp.Carriers.DHL
  defp carrier_module_for(:usps),  do: MyApp.Carriers.USPS
  defp carrier_module_for(c),      do: raise("Unknown carrier: #{c}")
end
# VALIDATION: SMELL END
```
