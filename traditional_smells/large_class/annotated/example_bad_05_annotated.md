# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `OrderManager` module
- **Affected function(s):** `place_order/2`, `confirm_order/1`, `fulfill_order/1`, `ship_order/2`, `cancel_order/2`, `request_return/2`, `approve_return/1`, `calculate_order_total/2`, `apply_coupon/2`, `notify_status_change/2`
- **Short explanation:** `OrderManager` merges order creation, lifecycle transitions (confirm → fulfill → ship → cancel), return handling, total calculation, coupon application, and customer status notifications into one module. These are at least five distinct business concerns that should each live in a dedicated module (e.g., `OrderPlacement`, `Fulfillment`, `ReturnPolicy`, `Pricing`, `OrderNotifier`).

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because OrderManager handles order placement,
# every order lifecycle transition, return/refund workflows, price and coupon
# calculation, and customer notifications — all distinct concerns that cause
# the module to be excessively large and poorly cohesive.
defmodule MyApp.OrderManager do
  @moduledoc """
  Manages the full lifecycle of customer orders — from placement
  through fulfillment, shipping, cancellation, and returns.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Orders.{Order, OrderItem, OrderReturn}
  alias MyApp.Accounts.User
  alias MyApp.Inventory.StockItem
  alias MyApp.Promotions.Coupon

  @return_window_days 30

  # -------------------------------------------------------------------
  # Order placement
  # -------------------------------------------------------------------

  def place_order(%User{} = user, cart_items) when is_list(cart_items) do
    with {:ok, validated} <- validate_cart_items(cart_items),
         {:ok, total}     <- calculate_order_total(validated, user) do

      Repo.transaction(fn ->
        order = Repo.insert!(%Order{
          user_id:    user.id,
          status:     :pending,
          subtotal:   total.subtotal,
          tax:        total.tax,
          total:      total.grand_total,
          placed_at:  DateTime.utc_now()
        })

        Enum.each(validated, fn item ->
          Repo.insert!(%OrderItem{
            order_id:   order.id,
            product_id: item.product_id,
            quantity:   item.quantity,
            unit_price: item.unit_price,
            line_total: item.quantity * item.unit_price
          })

          stock = Repo.get_by!(StockItem, product_id: item.product_id)
          Repo.update!(StockItem.changeset(stock, %{
            quantity_reserved: stock.quantity_reserved + item.quantity
          }))
        end)

        notify_status_change(order, :pending)
        order
      end)
    end
  end

  defp validate_cart_items(items) do
    results =
      Enum.map(items, fn item ->
        stock = Repo.get_by(StockItem, product_id: item.product_id)

        cond do
          is_nil(stock) ->
            {:error, "Product #{item.product_id} not found"}

          stock.quantity_on_hand - stock.quantity_reserved < item.quantity ->
            {:error, "Insufficient stock for product #{item.product_id}"}

          true ->
            {:ok, Map.put(item, :unit_price, stock.unit_price)}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors),
      do: {:ok, Enum.map(results, fn {:ok, v} -> v end)},
      else: {:error, Enum.map(errors, fn {:error, msg} -> msg end)}
  end

  # -------------------------------------------------------------------
  # Price and coupon calculation
  # -------------------------------------------------------------------

  def calculate_order_total(items, user, coupon_code \\ nil) do
    subtotal = Enum.reduce(items, 0, &(&1.quantity * &1.unit_price + &2))

    {discounted, coupon} =
      if coupon_code do
        case apply_coupon(subtotal, coupon_code) do
          {:ok, new_total, c} -> {new_total, c}
          _                   -> {subtotal, nil}
        end
      else
        {subtotal, nil}
      end

    tax   = round(discounted * tax_rate_for(user.country))
    total = discounted + tax

    {:ok, %{subtotal: subtotal, discounted: discounted, tax: tax,
            grand_total: total, coupon: coupon}}
  end

  def apply_coupon(subtotal, code) when is_binary(code) do
    case Repo.get_by(Coupon, code: String.upcase(code)) do
      nil ->
        {:error, :invalid_coupon}

      %Coupon{active: false} ->
        {:error, :coupon_inactive}

      %Coupon{expires_at: exp} when not is_nil(exp) and exp < DateTime.utc_now() ->
        {:error, :coupon_expired}

      %Coupon{discount_type: :percentage, discount_value: pct} = coupon ->
        new_total = round(subtotal * (1 - pct / 100.0))
        {:ok, new_total, coupon}

      %Coupon{discount_type: :fixed, discount_value: amount} = coupon ->
        new_total = max(0, subtotal - amount)
        {:ok, new_total, coupon}
    end
  end

  defp tax_rate_for("BR"), do: 0.12
  defp tax_rate_for("US"), do: 0.08
  defp tax_rate_for("DE"), do: 0.19
  defp tax_rate_for(_),    do: 0.10

  # -------------------------------------------------------------------
  # Order lifecycle transitions
  # -------------------------------------------------------------------

  def confirm_order(%Order{status: :pending} = order) do
    updated = Repo.update!(Order.changeset(order, %{status: :confirmed, confirmed_at: DateTime.utc_now()}))
    notify_status_change(updated, :confirmed)
    {:ok, updated}
  end

  def confirm_order(%Order{status: s}), do: {:error, "Cannot confirm order in status #{s}"}

  def fulfill_order(%Order{status: :confirmed} = order) do
    items = Repo.all(from oi in OrderItem, where: oi.order_id == ^order.id)

    Enum.each(items, fn item ->
      stock = Repo.get_by!(StockItem, product_id: item.product_id)
      Repo.update!(StockItem.changeset(stock, %{
        quantity_on_hand: stock.quantity_on_hand - item.quantity,
        quantity_reserved: max(0, stock.quantity_reserved - item.quantity)
      }))
    end)

    updated = Repo.update!(Order.changeset(order, %{status: :fulfilled, fulfilled_at: DateTime.utc_now()}))
    notify_status_change(updated, :fulfilled)
    {:ok, updated}
  end

  def fulfill_order(%Order{status: s}), do: {:error, "Cannot fulfill order in status #{s}"}

  def ship_order(%Order{status: :fulfilled} = order, tracking_info) do
    updated = Repo.update!(Order.changeset(order, %{
      status:           :shipped,
      shipped_at:       DateTime.utc_now(),
      tracking_number:  tracking_info[:tracking_number],
      carrier:          tracking_info[:carrier]
    }))

    notify_status_change(updated, :shipped)
    {:ok, updated}
  end

  def ship_order(%Order{status: s}, _), do: {:error, "Cannot ship order in status #{s}"}

  def cancel_order(%Order{status: status} = order, reason)
      when status in [:pending, :confirmed] do
    items = Repo.all(from oi in OrderItem, where: oi.order_id == ^order.id)

    Enum.each(items, fn item ->
      stock = Repo.get_by!(StockItem, product_id: item.product_id)
      Repo.update!(StockItem.changeset(stock, %{
        quantity_reserved: max(0, stock.quantity_reserved - item.quantity)
      }))
    end)

    updated = Repo.update!(Order.changeset(order, %{
      status:       :canceled,
      canceled_at:  DateTime.utc_now(),
      cancel_reason: reason
    }))

    notify_status_change(updated, :canceled)
    {:ok, updated}
  end

  def cancel_order(%Order{status: s}, _), do: {:error, "Cannot cancel order in status #{s}"}

  # -------------------------------------------------------------------
  # Returns
  # -------------------------------------------------------------------

  def request_return(%Order{status: :shipped} = order, reason) do
    cutoff = DateTime.add(order.shipped_at, @return_window_days * 86_400, :second)

    if DateTime.compare(DateTime.utc_now(), cutoff) == :gt do
      {:error, :return_window_expired}
    else
      return = Repo.insert!(%OrderReturn{
        order_id:    order.id,
        reason:      reason,
        status:      :pending,
        requested_at: DateTime.utc_now()
      })

      notify_status_change(order, :return_requested)
      {:ok, return}
    end
  end

  def request_return(%Order{status: s}, _), do: {:error, "Order in status #{s} cannot be returned"}

  def approve_return(%OrderReturn{status: :pending} = return) do
    updated = Repo.update!(OrderReturn.changeset(return, %{
      status:      :approved,
      approved_at: DateTime.utc_now()
    }))

    order = Repo.get!(Order, return.order_id)
    notify_status_change(order, :return_approved)
    {:ok, updated}
  end

  def approve_return(_), do: {:error, :not_pending}

  # -------------------------------------------------------------------
  # Customer notifications
  # -------------------------------------------------------------------

  def notify_status_change(%Order{} = order, event) do
    user = Repo.get!(User, order.user_id)

    message =
      case event do
        :pending          -> "Your order ##{order.id} has been placed."
        :confirmed        -> "Your order ##{order.id} is confirmed and being prepared."
        :fulfilled        -> "Your order ##{order.id} is packed and ready for dispatch."
        :shipped          -> "Your order ##{order.id} is on its way! Tracking: #{order.tracking_number}"
        :canceled         -> "Your order ##{order.id} has been canceled."
        :return_requested -> "Return for order ##{order.id} is under review."
        :return_approved  -> "Your return for order ##{order.id} has been approved."
        _                 -> "Your order ##{order.id} status has changed."
      end

    MyApp.Mailer.deliver(%{
      to:      user.email,
      subject: "Order Update: ##{order.id}",
      body:    message
    })

    Logger.info("Notified user #{user.id} of order #{order.id} event #{event}")
  end
end
# VALIDATION: SMELL END
```
