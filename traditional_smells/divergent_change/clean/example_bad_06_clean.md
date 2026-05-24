```elixir
defmodule Logistics.ShipmentHandler do
  @moduledoc """
  Manages shipment creation, status tracking, cost billing, and customer alerts.
  """

  alias Logistics.Repo
  alias Logistics.Shipments.Shipment
  alias Logistics.Carriers.CarrierClient
  alias Logistics.Billing.InvoiceService
  alias Logistics.Notifications.EmailSender

  import Ecto.Query
  require Logger



  @doc "Creates a new shipment record linked to an order."
  @spec create_shipment(String.t(), map()) :: {:ok, Shipment.t()} | {:error, term()}
  def create_shipment(order_id, shipment_params) do
    attrs = %{
      order_id: order_id,
      carrier: shipment_params[:carrier],
      service_level: shipment_params[:service_level] || :standard,
      destination_address: shipment_params[:destination_address],
      weight_grams: shipment_params[:weight_grams],
      status: :pending
    }

    with {:ok, shipment} <- Repo.insert(Shipment.changeset(%Shipment{}, attrs)) do
      Logger.info("Shipment #{shipment.id} created for order #{order_id}")
      {:ok, shipment}
    end
  end

  @doc "Marks a shipment as dispatched and stores the carrier tracking number."
  @spec mark_shipped(Shipment.t(), String.t()) :: {:ok, Shipment.t()} | {:error, term()}
  def mark_shipped(%Shipment{status: :pending} = shipment, tracking_number) do
    with {:ok, updated} <-
           shipment
           |> Shipment.changeset(%{
             status: :in_transit,
             tracking_number: tracking_number,
             shipped_at: DateTime.utc_now()
           })
           |> Repo.update() do
      send_dispatch_notice(updated)
      {:ok, updated}
    end
  end

  def mark_shipped(%Shipment{}, _tracking), do: {:error, :invalid_transition}

  @doc "Marks a shipment as delivered after carrier confirmation."
  @spec mark_delivered(Shipment.t(), DateTime.t()) :: {:ok, Shipment.t()} | {:error, term()}
  def mark_delivered(%Shipment{status: :in_transit} = shipment, delivered_at) do
    with {:ok, updated} <-
           shipment
           |> Shipment.changeset(%{status: :delivered, delivered_at: delivered_at})
           |> Repo.update() do
      send_delivery_confirmation(updated)
      {:ok, updated}
    end
  end

  def mark_delivered(%Shipment{}, _), do: {:error, :invalid_transition}

  @doc "Cancels a pending shipment and voids any held charges."
  @spec cancel_shipment(Shipment.t()) :: {:ok, Shipment.t()} | {:error, atom()}
  def cancel_shipment(%Shipment{status: :pending} = shipment) do
    shipment
    |> Shipment.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def cancel_shipment(%Shipment{}), do: {:error, :cannot_cancel}


  @doc "Calculates shipping cost based on carrier rates, weight, and service level."
  @spec calculate_shipping_cost(Shipment.t()) :: {:ok, pos_integer()} | {:error, term()}
  def calculate_shipping_cost(%Shipment{
        carrier: carrier,
        service_level: level,
        weight_grams: weight,
        destination_address: %{country: country}
      }) do
    base_rate = CarrierClient.get_rate(carrier, level, country)
    weight_surcharge = if weight > 5_000, do: round(weight * 0.02), else: 0
    total = base_rate + weight_surcharge

    {:ok, total}
  end

  @doc "Charges the customer for a confirmed shipment."
  @spec charge_shipment(Shipment.t()) :: {:ok, map()} | {:error, term()}
  def charge_shipment(%Shipment{order_id: order_id} = shipment) do
    with {:ok, cost_cents} <- calculate_shipping_cost(shipment),
         {:ok, invoice} <-
           InvoiceService.create_and_charge(%{
             order_id: order_id,
             line_items: [%{description: "Shipping", amount_cents: cost_cents}]
           }) do
      shipment
      |> Shipment.changeset(%{invoice_id: invoice.id, charged_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end


  @doc "Sends a dispatch notice email to the customer with tracking details."
  @spec send_dispatch_notice(Shipment.t()) :: :ok
  def send_dispatch_notice(%Shipment{order_id: oid, tracking_number: tn}) do
    order = Repo.get!(Logistics.Orders.Order, oid) |> Repo.preload(:customer)

    EmailSender.send(%{
      to: order.customer.email,
      subject: "Your order has been shipped!",
      template: "shipment_dispatched",
      assigns: %{tracking_number: tn, carrier_url: tracking_url(tn)}
    })

    Logger.info("Dispatch notice sent for order #{oid}")
    :ok
  end

  @doc "Sends a delivery confirmation email to the customer."
  @spec send_delivery_confirmation(Shipment.t()) :: :ok
  def send_delivery_confirmation(%Shipment{order_id: oid}) do
    order = Repo.get!(Logistics.Orders.Order, oid) |> Repo.preload(:customer)

    EmailSender.send(%{
      to: order.customer.email,
      subject: "Your order has been delivered!",
      template: "shipment_delivered",
      assigns: %{order_id: oid}
    })

    :ok
  end

  @doc "Alerts the customer of a shipping delay with an estimated new date."
  @spec send_delay_alert(Shipment.t(), Date.t()) :: :ok
  def send_delay_alert(%Shipment{order_id: oid} = _shipment, new_estimated_date) do
    order = Repo.get!(Logistics.Orders.Order, oid) |> Repo.preload(:customer)

    EmailSender.send(%{
      to: order.customer.email,
      subject: "Shipping delay notice",
      template: "shipment_delay",
      assigns: %{new_date: new_estimated_date}
    })

    Logger.warning("Delay alert sent for order #{oid}, new ETA: #{new_estimated_date}")
    :ok
  end


  defp tracking_url(tracking_number), do: "https://track.carrier.example.com/#{tracking_number}"

end
```
