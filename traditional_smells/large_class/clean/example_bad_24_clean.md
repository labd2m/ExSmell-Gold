```elixir
defmodule OrderManager do
  @moduledoc """
  Central module for order lifecycle management.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Orders.{Order, OrderItem, OrderStatusHistory, ReturnRequest}
  alias MyApp.Inventory.StockLevel
  alias MyApp.Mailer
  alias MyApp.Accounts.User

  @valid_transitions %{
    pending: [:confirmed, :cancelled],
    confirmed: [:processing, :cancelled],
    processing: [:shipped, :cancelled],
    shipped: [:delivered, :return_requested],
    delivered: [:return_requested],
    return_requested: [:return_approved, :return_rejected],
    return_approved: [:refunded],
    return_rejected: [:delivered],
    cancelled: [],
    refunded: []
  }

  @return_window_days 30


  def create_order(user_id, items, shipping_address) do
    user = Repo.get!(User, user_id)

    with :ok <- validate_items_available(items),
         {:ok, order} <-
           Repo.insert(%Order{
             user_id: user_id,
             shipping_address: shipping_address,
             status: :pending,
             placed_at: DateTime.utc_now()
           }),
         {:ok, _} <- insert_order_items(order.id, items),
         {:ok, _} <- record_status_change(order.id, nil, :pending, "Order placed") do
      send_order_confirmation(user, order)
      {:ok, order}
    end
  end

  defp validate_items_available(items) do
    unavailable =
      Enum.reject(items, fn item ->
        case Repo.get_by(StockLevel, sku: item.sku) do
          %StockLevel{quantity: q} when q >= item.quantity -> true
          _ -> false
        end
      end)

    if Enum.empty?(unavailable), do: :ok, else: {:error, {:out_of_stock, Enum.map(unavailable, & &1.sku)}}
  end

  defp insert_order_items(order_id, items) do
    result =
      Enum.map(items, fn item ->
        Repo.insert(%OrderItem{
          order_id: order_id,
          sku: item.sku,
          quantity: item.quantity,
          unit_price: item.unit_price,
          total_price: Decimal.mult(item.unit_price, item.quantity)
        })
      end)

    if Enum.all?(result, &match?({:ok, _}, &1)),
      do: {:ok, result},
      else: {:error, :item_insert_failed}
  end


  def transition(order_id, new_status, note \\ nil) do
    order = Repo.get!(Order, order_id)
    allowed = Map.get(@valid_transitions, order.status, [])

    if new_status in allowed do
      with {:ok, updated} <-
             order
             |> Order.changeset(%{status: new_status})
             |> Repo.update(),
           {:ok, _} <-
             record_status_change(order_id, order.status, new_status, note) do
        on_transition(updated, order.status, new_status)
        {:ok, updated}
      end
    else
      {:error, {:invalid_transition, order.status, new_status}}
    end
  end

  defp record_status_change(order_id, from, to, note) do
    Repo.insert(%OrderStatusHistory{
      order_id: order_id,
      from_status: from,
      to_status: to,
      note: note,
      occurred_at: DateTime.utc_now()
    })
  end

  defp on_transition(order, _from, :shipped) do
    user = Repo.get!(User, order.user_id)
    send_shipment_notification(user, order)
  end

  defp on_transition(order, _from, :delivered) do
    user = Repo.get!(User, order.user_id)
    send_delivery_confirmation(user, order)
  end

  defp on_transition(_order, _from, _to), do: :ok


  def mark_as_processing(order_id) do
    order = Repo.get!(Order, order_id)
    items = Repo.all(from i in OrderItem, where: i.order_id == ^order_id)

    Enum.each(items, fn item ->
      sl = Repo.get_by!(StockLevel, sku: item.sku)
      sl |> StockLevel.changeset(%{quantity: sl.quantity - item.quantity}) |> Repo.update()
    end)

    transition(order_id, :processing, "Stock reserved and fulfillment started")
  end

  def assign_to_warehouse(order_id, warehouse_id) do
    Repo.get!(Order, order_id)
    |> Order.changeset(%{warehouse_id: warehouse_id, assigned_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def attach_tracking(order_id, carrier, tracking_number) do
    with {:ok, updated} <-
           Repo.get!(Order, order_id)
           |> Order.changeset(%{carrier: carrier, tracking_number: tracking_number})
           |> Repo.update(),
         {:ok, _} <- transition(order_id, :shipped, "Tracking attached: #{tracking_number}") do
      {:ok, updated}
    end
  end


  def request_return(order_id, reason, items_to_return) do
    order = Repo.get!(Order, order_id)
    age_days = DateTime.diff(DateTime.utc_now(), order.placed_at, :day)

    if age_days > @return_window_days do
      {:error, :return_window_expired}
    else
      with {:ok, rma} <-
             Repo.insert(%ReturnRequest{
               order_id: order_id,
               reason: reason,
               items: items_to_return,
               status: :pending,
               requested_at: DateTime.utc_now()
             }),
           {:ok, _} <- transition(order_id, :return_requested, "RMA #{rma.id} opened") do
        user = Repo.get!(User, order.user_id)
        send_return_confirmation(user, order, rma)
        {:ok, rma}
      end
    end
  end

  def approve_return(rma_id) do
    rma = Repo.get!(ReturnRequest, rma_id)

    rma
    |> ReturnRequest.changeset(%{status: :approved, reviewed_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        transition(rma.order_id, :return_approved, "Return approved")
        {:ok, updated}

      err ->
        err
    end
  end


  defp send_order_confirmation(user, order) do
    Mailer.send(%{
      to: user.email,
      subject: "Order ##{order.id} confirmed",
      body: "Thank you for your order! It will be processed shortly."
    })
  end

  defp send_shipment_notification(user, order) do
    Mailer.send(%{
      to: user.email,
      subject: "Your order ##{order.id} has shipped",
      body: "Track your package with #{order.carrier}: #{order.tracking_number}"
    })
  end

  defp send_delivery_confirmation(user, order) do
    Mailer.send(%{
      to: user.email,
      subject: "Order ##{order.id} delivered",
      body: "Your order has been delivered. Enjoy! Contact us if anything is wrong."
    })
  end

  defp send_return_confirmation(user, order, rma) do
    Mailer.send(%{
      to: user.email,
      subject: "Return RMA ##{rma.id} for order ##{order.id}",
      body: "We've received your return request. We'll notify you of the outcome."
    })
  end
end
```
