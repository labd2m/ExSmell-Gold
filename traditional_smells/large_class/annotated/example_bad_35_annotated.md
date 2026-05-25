# Annotated Example — Large Module

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `OrderFulfillment` module
- **Affected functions:** `place_order/2`, `validate_stock/1`, `reserve_inventory/1`, `generate_shipping_label/1`, `notify_customer/2`, `update_order_status/2`, `cancel_order/2`, `calculate_estimated_delivery/2`, `build_order_summary/1`
- **Short explanation:** `OrderFulfillment` combines order placement, stock validation and reservation (inventory domain), shipping label generation (logistics domain), customer notification (communication domain), and delivery-date estimation into one module. These are clearly separate bounded contexts that should live in dedicated modules, making the current module a textbook Large Module.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because OrderFulfillment handles order creation,
# inventory validation and reservation, shipping label generation, customer
# notifications, and delivery estimation — each a distinct bounded context —
# all inside a single, oversized module with poor cohesion.
defmodule OrderFulfillment do
  @moduledoc """
  End-to-end order processing: placement, inventory reservation,
  shipping label creation, customer notifications, and status tracking.
  """

  require Logger
  alias Store.Repo
  alias Store.Order
  alias Store.OrderItem
  alias Store.Product
  alias Store.ShippingLabel

  @carrier_codes %{standard: "STD", express: "EXP", overnight: "OVN"}
  @processing_days %{standard: 5, express: 2, overnight: 1}

  # --- Order placement ---

  def place_order(user, cart_items) do
    Repo.transaction(fn ->
      with :ok <- validate_stock(cart_items),
           {:ok, order} <- insert_order(user, cart_items),
           :ok <- reserve_inventory(cart_items),
           {:ok, label} <- generate_shipping_label(order),
           :ok <- notify_customer(order, user) do
        {:ok, order, label}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_order(user, items) do
    total =
      Enum.reduce(items, Decimal.new("0"), fn i, acc ->
        Decimal.add(acc, Decimal.mult(i.price, i.quantity))
      end)

    changeset =
      Order.changeset(%Order{}, %{
        user_id: user.id,
        status: :confirmed,
        total: total,
        placed_at: DateTime.utc_now()
      })

    case Repo.insert(changeset) do
      {:ok, order} ->
        Enum.each(items, fn item ->
          Repo.insert!(
            OrderItem.changeset(%OrderItem{}, %{
              order_id: order.id,
              product_id: item.product_id,
              quantity: item.quantity,
              unit_price: item.price
            })
          )
        end)
        {:ok, order}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # --- Inventory validation and reservation ---

  def validate_stock(items) do
    out_of_stock =
      Enum.filter(items, fn item ->
        product = Repo.get!(Product, item.product_id)
        product.stock_quantity < item.quantity
      end)

    if Enum.empty?(out_of_stock) do
      :ok
    else
      ids = Enum.map(out_of_stock, & &1.product_id)
      {:error, {:out_of_stock, ids}}
    end
  end

  def reserve_inventory(items) do
    Enum.each(items, fn item ->
      product = Repo.get!(Product, item.product_id)
      new_qty = product.stock_quantity - item.quantity

      product
      |> Product.changeset(%{stock_quantity: new_qty, reserved_quantity: product.reserved_quantity + item.quantity})
      |> Repo.update!()
    end)

    :ok
  end

  # --- Shipping label generation ---

  def generate_shipping_label(%Order{} = order) do
    carrier_code = Map.get(@carrier_codes, order.shipping_method || :standard)

    tracking_number =
      "#{carrier_code}-#{:erlang.unique_integer([:positive])}-#{order.id}"

    label_attrs = %{
      order_id: order.id,
      tracking_number: tracking_number,
      carrier: carrier_code,
      created_at: DateTime.utc_now()
    }

    case Repo.insert(ShippingLabel.changeset(%ShippingLabel{}, label_attrs)) do
      {:ok, label} ->
        Logger.info("Shipping label #{tracking_number} created for order #{order.id}")
        {:ok, label}

      {:error, cs} ->
        Logger.error("Failed to create shipping label: #{inspect(cs.errors)}")
        {:error, cs}
    end
  end

  # --- Customer notifications ---

  def notify_customer(%Order{} = order, user) do
    summary = build_order_summary(order)

    body = """
    Hello #{user.name},

    Your order ##{order.id} has been confirmed. Here is your summary:

    #{summary}

    We will notify you once your order ships.
    """

    case Mailer.deliver(%{
           to: user.email,
           subject: "Order Confirmation — ##{order.id}",
           text_body: body
         }) do
      {:ok, _} ->
        Logger.info("Confirmation email sent to #{user.email} for order #{order.id}")
        :ok

      {:error, reason} ->
        Logger.warning("Could not send confirmation email: #{inspect(reason)}")
        :ok
    end
  end

  # --- Status management ---

  def update_order_status(%Order{} = order, new_status)
      when new_status in [:confirmed, :processing, :shipped, :delivered, :cancelled] do
    order
    |> Order.changeset(%{status: new_status, updated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def cancel_order(%Order{status: status}, _reason) when status in [:shipped, :delivered] do
    {:error, :cannot_cancel_shipped_order}
  end

  def cancel_order(%Order{} = order, reason) do
    Repo.transaction(fn ->
      {:ok, cancelled} = update_order_status(order, :cancelled)
      release_inventory(order)
      AuditLog.record(:order_cancelled, %{order_id: order.id, reason: reason})
      cancelled
    end)
  end

  defp release_inventory(%Order{} = order) do
    order = Repo.preload(order, :order_items)

    Enum.each(order.order_items, fn item ->
      product = Repo.get!(Product, item.product_id)

      product
      |> Product.changeset(%{
           stock_quantity: product.stock_quantity + item.quantity,
           reserved_quantity: max(0, product.reserved_quantity - item.quantity)
         })
      |> Repo.update!()
    end)
  end

  # --- Delivery estimation ---

  def calculate_estimated_delivery(order, ship_date \\ Date.utc_today()) do
    days = Map.get(@processing_days, order.shipping_method || :standard)
    Date.add(ship_date, days)
  end

  # --- Summary helper ---

  def build_order_summary(%Order{} = order) do
    order = Repo.preload(order, :order_items)

    lines =
      Enum.map(order.order_items, fn item ->
        "  - Product #{item.product_id}: #{item.quantity} x $#{item.unit_price}"
      end)

    Enum.join(lines, "\n") <> "\n  Total: $#{order.total}"
  end
end
# VALIDATION: SMELL END
```
