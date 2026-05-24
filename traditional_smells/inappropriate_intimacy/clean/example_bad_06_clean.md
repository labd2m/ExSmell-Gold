```elixir
defmodule Logistics.ShipmentBuilder do
  @moduledoc """
  Creates outbound shipment records and dispatches carrier booking requests.
  Validates weight constraints and formats address labels for the selected carrier.
  """

  alias Logistics.{Shipment, ShipmentLabel, Repo}
  alias Orders.Order
  alias Carriers.Carrier

  require Logger

  @shipment_id_prefix "SHP"
  @weight_safety_margin_grams 50

  @spec create(String.t(), String.t(), map()) ::
          {:ok, Shipment.t()} | {:error, atom()}
  def create(order_id, carrier_id, parcel) do
    with {:ok, order}   <- Order.fetch(order_id),
         :ok            <- ensure_order_ready(order),
         {:ok, carrier} <- Carrier.fetch(carrier_id) do

      address = Order.fetch_delivery_address(order)
      config  = Carrier.get_service_config(carrier, parcel.service_level)

      total_weight_grams = parcel.weight_grams + @weight_safety_margin_grams

      if total_weight_grams > config.max_weight_grams do
        {:error, :parcel_exceeds_carrier_weight_limit}
      else
        booking_payload = %{
          service_code:   config.service_code,
          tracking:       config.tracking_enabled,
          recipient: %{
            name:         address.recipient_name,
            street_line1: address.street_line1,
            street_line2: address.street_line2,
            city:         address.city,
            postal_code:  address.postal_code,
            country_code: address.country_code
          },
          parcel: %{
            weight_grams: total_weight_grams,
            length_mm:    parcel.length_mm,
            width_mm:     parcel.width_mm,
            height_mm:    parcel.height_mm
          }
        }

        case Carrier.book_shipment(carrier, booking_payload) do
          {:ok, booking} ->
            shipment = persist_shipment(order_id, carrier_id, address, config, booking, parcel)
            Logger.info("[ShipmentBuilder] Created shipment=#{shipment.id} for order=#{order_id}")
            {:ok, shipment}

          {:error, reason} ->
            Logger.error("[ShipmentBuilder] Carrier booking failed: #{inspect(reason)}")
            {:error, :carrier_booking_failed}
        end
      end
    end
  end

  @spec cancel(String.t()) :: :ok | {:error, atom()}
  def cancel(shipment_id) do
    with {:ok, shipment} <- fetch_by_id(shipment_id),
         :ok             <- ensure_cancellable(shipment) do
      {:ok, carrier} = Carrier.fetch(shipment.carrier_id)
      :ok = Carrier.cancel_booking(carrier, shipment.carrier_booking_ref)

      shipment
      |> Shipment.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
      |> Repo.update()

      :ok
    end
  end

  @spec mark_dispatched(String.t()) :: {:ok, Shipment.t()} | {:error, atom()}
  def mark_dispatched(shipment_id) do
    with {:ok, shipment} <- fetch_by_id(shipment_id),
         :ok             <- ensure_status(shipment, :booked) do
      shipment
      |> Shipment.changeset(%{status: :dispatched, dispatched_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end


  defp persist_shipment(order_id, carrier_id, address, config, booking, parcel) do
    {:ok, shipment} =
      %Shipment{
        id:                  "#{@shipment_id_prefix}-#{:crypto.strong_rand_bytes(6) |> Base.encode16()}",
        order_id:            order_id,
        carrier_id:          carrier_id,
        carrier_booking_ref: booking.reference,
        tracking_number:     booking.tracking_number,
        service_code:        config.service_code,
        destination_country: address.country_code,
        weight_grams:        parcel.weight_grams,
        status:              :booked,
        created_at:          DateTime.utc_now()
      }
      |> Repo.insert()

    if booking.label_url do
      ShipmentLabel.store(shipment.id, booking.label_url)
    end

    shipment
  end

  defp ensure_order_ready(%{status: :confirmed}), do: :ok
  defp ensure_order_ready(_), do: {:error, :order_not_ready_for_shipment}

  defp ensure_cancellable(%{status: status}) when status in [:booked, :pending], do: :ok
  defp ensure_cancellable(_), do: {:error, :shipment_not_cancellable}

  defp ensure_status(%{status: s}, expected) when s == expected, do: :ok
  defp ensure_status(_, _), do: {:error, :unexpected_shipment_status}

  defp fetch_by_id(id) do
    case Repo.get(Shipment, id) do
      nil -> {:error, :not_found}
      s   -> {:ok, s}
    end
  end
end
```
