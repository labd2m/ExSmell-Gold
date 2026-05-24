```elixir
defmodule Commerce.OrderProcessor do
  @moduledoc """
  Central module for handling customer order operations.
  """

  alias Commerce.Repo
  alias Commerce.Orders.Order
  alias Commerce.Inventory.StockItem
  alias Commerce.Notifications.Dispatcher
  alias Commerce.Accounts.Customer

  import Ecto.Query
  require Logger



  @doc "Creates and persists a new order from a customer's cart."
  @spec place_order(Customer.t(), map()) :: {:ok, Order.t()} | {:error, Ecto.Changeset.t()}
  def place_order(%Customer{id: customer_id}, cart_params) do
    Repo.transaction(fn ->
      changeset =
        Order.changeset(%Order{}, %{
          customer_id: customer_id,
          status: :pending,
          line_items: cart_params[:line_items],
          shipping_address: cart_params[:shipping_address]
        })

      case Repo.insert(changeset) do
        {:ok, order} ->
          case reserve_stock(order) do
            :ok ->
              notify_customer(order, :order_placed)
              order

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Cancels an order if it is still in a cancellable state."
  @spec cancel_order(Order.t(), String.t()) :: {:ok, Order.t()} | {:error, atom()}
  def cancel_order(%Order{status: status} = order, reason) when status in [:pending, :confirmed] do
    Repo.transaction(fn ->
      {:ok, updated} =
        order
        |> Order.changeset(%{status: :cancelled, cancellation_reason: reason})
        |> Repo.update()

      release_stock(updated)
      notify_customer(updated, :order_cancelled)
      updated
    end)
  end

  def cancel_order(%Order{}, _reason), do: {:error, :not_cancellable}

  @doc "Marks an order as confirmed and informs the warehouse."
  @spec confirm_order(Order.t()) :: {:ok, Order.t()} | {:error, term()}
  def confirm_order(%Order{status: :pending} = order) do
    {:ok, updated} =
      order
      |> Order.changeset(%{status: :confirmed, confirmed_at: DateTime.utc_now()})
      |> Repo.update()

    notify_warehouse(updated)
    {:ok, updated}
  end

  def confirm_order(%Order{}), do: {:error, :invalid_status}


  @doc "Reserves stock for every line item in the order."
  @spec reserve_stock(Order.t()) :: :ok | {:error, String.t()}
  def reserve_stock(%Order{line_items: items}) do
    Enum.reduce_while(items, :ok, fn %{product_id: pid, quantity: qty}, _acc ->
      stock = Repo.get_by!(StockItem, product_id: pid)

      if stock.available >= qty do
        stock
        |> StockItem.changeset(%{available: stock.available - qty, reserved: stock.reserved + qty})
        |> Repo.update!()

        {:cont, :ok}
      else
        {:halt, {:error, "Insufficient stock for product #{pid}"}}
      end
    end)
  end

  @doc "Releases previously reserved stock back to available."
  @spec release_stock(Order.t()) :: :ok
  def release_stock(%Order{line_items: items}) do
    Enum.each(items, fn %{product_id: pid, quantity: qty} ->
      stock = Repo.get_by!(StockItem, product_id: pid)

      stock
      |> StockItem.changeset(%{available: stock.available + qty, reserved: stock.reserved - qty})
      |> Repo.update!()
    end)
  end

  @doc "Manually adjusts stock count for a product, e.g. after a stock audit."
  @spec adjust_inventory(pos_integer(), integer()) :: {:ok, StockItem.t()} | {:error, term()}
  def adjust_inventory(product_id, delta) do
    stock = Repo.get_by!(StockItem, product_id: product_id)
    new_available = max(stock.available + delta, 0)

    stock
    |> StockItem.changeset(%{available: new_available})
    |> Repo.update()
  end


  @doc "Sends a customer-facing notification for a given order event."
  @spec notify_customer(Order.t(), atom()) :: :ok
  def notify_customer(%Order{customer_id: cid} = order, event) do
    customer = Repo.get!(Customer, cid)

    payload = %{
      to: customer.email,
      template: template_for(event),
      assigns: %{order_id: order.id, total: order.total_amount}
    }

    case Dispatcher.send_email(payload) do
      :ok -> Logger.info("Customer notification sent for order #{order.id}, event=#{event}")
      {:error, reason} -> Logger.warning("Failed to notify customer: #{inspect(reason)}")
    end
  end

  @doc "Sends a fulfillment notification to the warehouse system."
  @spec notify_warehouse(Order.t()) :: :ok
  def notify_warehouse(%Order{} = order) do
    payload = %{
      order_id: order.id,
      line_items: order.line_items,
      shipping_address: order.shipping_address
    }

    Dispatcher.send_webhook(:warehouse, payload)
    Logger.info("Warehouse notified for order #{order.id}")
  end


  defp template_for(:order_placed), do: "order_confirmation"
  defp template_for(:order_cancelled), do: "order_cancellation"
  defp template_for(_), do: "order_update"

end
```
