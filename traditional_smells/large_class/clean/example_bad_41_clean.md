```elixir
defmodule ShipmentManager do
  @moduledoc """
  End-to-end shipment operations: carrier booking, label generation, tracking,
  recipient notifications, exception handling, freight pricing, delivery
  confirmation, and return initiation.
  """

  require Logger
  alias Logistics.Repo
  alias Logistics.Shipment
  alias Logistics.TrackingEvent
  alias Logistics.Return

  @carriers %{
    fedex: %{code: "FEDEX", base_rate: 8.50},
    ups:   %{code: "UPS",   base_rate: 7.90},
    dhl:   %{code: "DHL",   base_rate: 9.20}
  }

  @weight_rate_per_kg 1.25


  def create_shipment(order, opts \\ []) do
    carrier_key = Keyword.get(opts, :carrier, :fedex)
    service     = Keyword.get(opts, :service, :ground)

    attrs = %{
      order_id: order.id,
      carrier: carrier_key,
      service: service,
      origin_address: order.warehouse_address,
      destination_address: order.shipping_address,
      status: :pending,
      created_at: DateTime.utc_now()
    }

    case Repo.insert(Shipment.changeset(%Shipment{}, attrs)) do
      {:ok, shipment} ->
        {:ok, booked} = book_carrier(shipment, carrier_key)
        {:ok, booked}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def book_carrier(%Shipment{} = shipment, carrier_key) do
    carrier = Map.fetch!(@carriers, carrier_key)

    booking_payload = %{
      shipper_account: Application.fetch_env!(:logistics, :"#{carrier_key}_account"),
      origin: shipment.origin_address,
      destination: shipment.destination_address,
      service: shipment.service
    }

    case CarrierAPI.book(carrier.code, booking_payload) do
      {:ok, %{tracking_number: tn, label_url: label_url}} ->
        shipment
        |> Shipment.changeset(%{tracking_number: tn, label_url: label_url, status: :booked})
        |> Repo.update()

      {:error, reason} ->
        Logger.error("Carrier booking failed (#{carrier_key}): #{inspect(reason)}")
        {:error, reason}
    end
  end


  def print_label(%Shipment{label_url: nil}), do: {:error, :label_not_ready}

  def print_label(%Shipment{label_url: url} = shipment) do
    case HTTPoison.get(url, [], follow_redirect: true) do
      {:ok, %{status_code: 200, body: pdf_bytes}} ->
        path = "/tmp/label_#{shipment.id}.pdf"
        File.write!(path, pdf_bytes)
        Logger.info("Label for shipment #{shipment.id} saved to #{path}")
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end


  def update_tracking(%Shipment{} = shipment, event_params) do
    event_attrs = Map.merge(event_params, %{
      shipment_id: shipment.id,
      occurred_at: event_params[:occurred_at] || DateTime.utc_now()
    })

    with {:ok, event} <- Repo.insert(TrackingEvent.changeset(%TrackingEvent{}, event_attrs)) do
      new_status = derive_status(event.event_code)

      if new_status != shipment.status do
        shipment |> Shipment.changeset(%{status: new_status}) |> Repo.update!()
      end

      {:ok, event}
    end
  end

  defp derive_status(code) do
    case code do
      "IN_TRANSIT"  -> :in_transit
      "OUT_FOR_DEL" -> :out_for_delivery
      "DELIVERED"   -> :delivered
      "EXCEPTION"   -> :exception
      _             -> :unknown
    end
  end


  def notify_recipient(%Shipment{} = shipment, event) do
    order = Repo.get!(Logistics.Order, shipment.order_id)
    recipient = Repo.get!(Logistics.User, order.user_id)

    message =
      case event.event_code do
        "IN_TRANSIT"  -> "Your package is on its way. Tracking: #{shipment.tracking_number}"
        "OUT_FOR_DEL" -> "Your package will be delivered today!"
        "DELIVERED"   -> "Your package has been delivered. Enjoy!"
        "EXCEPTION"   -> "There is a delivery exception for your package. We are looking into it."
        _             -> "There is an update on your shipment #{shipment.tracking_number}."
      end

    Mailer.deliver(%{
      to: recipient.email,
      subject: "Shipment Update — #{shipment.tracking_number}",
      text_body: message
    })
  end


  def handle_delivery_exception(%Shipment{} = shipment, exception_code) do
    Logger.warning("Delivery exception #{exception_code} for shipment #{shipment.id}")

    case exception_code do
      "ADDRESS_NOT_FOUND" ->
        shipment |> Shipment.changeset(%{status: :exception, exception_reason: "Address not found"}) |> Repo.update()

      "RECIPIENT_UNAVAILABLE" ->
        shipment |> Shipment.changeset(%{status: :exception, exception_reason: "Recipient unavailable"}) |> Repo.update()

      _ ->
        shipment |> Shipment.changeset(%{status: :exception, exception_reason: exception_code}) |> Repo.update()
    end
  end


  def calculate_freight_cost(weight_kg, carrier_key) do
    carrier = Map.get(@carriers, carrier_key, @carriers.fedex)
    Float.round(carrier.base_rate + weight_kg * @weight_rate_per_kg, 2)
  end


  def confirm_delivery(%Shipment{status: :delivered} = shipment) do
    shipment
    |> Shipment.changeset(%{confirmed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def confirm_delivery(%Shipment{} = shipment), do: {:error, {:not_delivered, shipment.status}}


  def initiate_return(%Shipment{} = shipment, reason) do
    return_attrs = %{
      shipment_id: shipment.id,
      reason: reason,
      status: :initiated,
      created_at: DateTime.utc_now()
    }

    case Repo.insert(Return.changeset(%Return{}, return_attrs)) do
      {:ok, ret} ->
        Logger.info("Return #{ret.id} initiated for shipment #{shipment.id}")
        {:ok, ret}

      {:error, cs} ->
        {:error, cs}
    end
  end
end
```
