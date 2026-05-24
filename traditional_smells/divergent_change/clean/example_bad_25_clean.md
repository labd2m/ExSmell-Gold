```elixir
defmodule MyApp.OrderProcessor do
  @moduledoc """
  Central module for handling order placement, inventory reservation,
  and shipment scheduling within the fulfillment pipeline.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Order, OrderItem, StockReservation, Shipment}
  alias MyApp.Events
  import Ecto.Query



  @doc """
  Places a new order for a customer, persisting items and triggering downstream steps.
  """
  def place_order(customer_id, items) when is_list(items) do
    Repo.transaction(fn ->
      order =
        %Order{}
        |> Order.changeset(%{
          customer_id: customer_id,
          status: :pending,
          placed_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      Enum.each(items, fn %{product_id: pid, quantity: qty, unit_price: price} ->
        %OrderItem{}
        |> OrderItem.changeset(%{order_id: order.id, product_id: pid, quantity: qty, unit_price: price})
        |> Repo.insert!()
      end)

      Events.publish("order.placed", %{order_id: order.id, customer_id: customer_id})
      order
    end)
  end

  @doc """
  Cancels an existing order if it has not yet been shipped.
  """
  def cancel_order(%Order{status: status}, _reason) when status in [:shipped, :delivered] do
    {:error, :cannot_cancel_after_shipment}
  end

  def cancel_order(%Order{} = order, reason) do
    order
    |> Order.changeset(%{status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Events.publish("order.cancelled", %{order_id: updated.id, reason: reason})
        {:ok, updated}

      error ->
        error
    end
  end


  @doc """
  Reserves stock for each item in an order, reducing available quantities.
  """
  def reserve_stock(%Order{} = order, items) do
    Repo.transaction(fn ->
      Enum.map(items, fn %{product_id: pid, quantity: qty} ->
        updated =
          from(p in MyApp.Schemas.Product, where: p.id == ^pid)
          |> Repo.update_all(inc: [reserved_quantity: qty])

        case updated do
          {1, _} ->
            %StockReservation{}
            |> StockReservation.changeset(%{order_id: order.id, product_id: pid, quantity: qty})
            |> Repo.insert!()

          _ ->
            Repo.rollback({:insufficient_stock, pid})
        end
      end)
    end)
  end

  @doc """
  Releases previously reserved stock when an order is cancelled or expired.
  """
  def release_stock(%Order{id: order_id}) do
    reservations = Repo.all(from r in StockReservation, where: r.order_id == ^order_id)

    Repo.transaction(fn ->
      Enum.each(reservations, fn res ->
        from(p in MyApp.Schemas.Product, where: p.id == ^res.product_id)
        |> Repo.update_all(inc: [reserved_quantity: -res.quantity])

        Repo.delete!(res)
      end)
    end)
  end


  @doc """
  Creates a shipment record and schedules pickup with the carrier.
  """
  def schedule_shipment(%Order{} = order, carrier_code) do
    tracking_number = MyApp.CarrierGateway.request_label(carrier_code, order)

    %Shipment{}
    |> Shipment.changeset(%{
      order_id: order.id,
      carrier_code: carrier_code,
      tracking_number: tracking_number,
      status: :scheduled,
      estimated_delivery: Date.add(Date.utc_today(), carrier_transit_days(carrier_code))
    })
    |> Repo.insert()
  end

  @doc """
  Fetches real-time tracking status from the carrier's API.
  """
  def track_shipment(%Shipment{tracking_number: tn, carrier_code: code}) do
    case MyApp.CarrierGateway.fetch_status(code, tn) do
      {:ok, %{status: status, location: loc}} ->
        {:ok, %{status: status, current_location: loc}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp carrier_transit_days("FEDEX"), do: 2
  defp carrier_transit_days("UPS"), do: 3
  defp carrier_transit_days(_), do: 5

end
```
