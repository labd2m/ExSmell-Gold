# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `CartManager.add_item/4`, where `quantity` is multiplied by `unit_price`
- **Affected function(s):** `add_item/4`, `recalculate_totals/1`
- **Short explanation:** The `quantity` parameter is passed directly into a multiplication expression (`quantity * product.unit_price`) without any upfront check that it is a positive integer. A caller sending a string such as `"2"` or a float will trigger an `ArithmeticError` deep inside `recalculate_totals/1`, with no indication that the invalid value originated at the `add_item/4` boundary.

```elixir
defmodule MyApp.Commerce.CartManager do
  @moduledoc """
  Manages shopping cart lifecycle including item addition, removal, quantity
  updates, coupon application, and cart-to-order promotion.
  """

  require Logger

  alias MyApp.Commerce.{Cart, CartItem, ProductCatalog, CouponEngine}
  alias MyApp.Accounts.Customer

  @max_quantity_per_item 999
  @max_distinct_items 100
  @cart_expiry_hours 72

  @type add_opts :: [
          replace_quantity: boolean(),
          note: String.t()
        ]

  @spec add_item(String.t(), String.t(), term(), add_opts()) ::
          {:ok, Cart.t()} | {:error, atom()}
  def add_item(cart_id, sku, quantity, opts \\ []) do
    replace = Keyword.get(opts, :replace_quantity, false)
    note = Keyword.get(opts, :note)

    with {:ok, cart} <- fetch_active_cart(cart_id),
         {:ok, product} <- ProductCatalog.fetch(sku),
         :ok <- check_stock_availability(product, quantity),
         :ok <- check_cart_capacity(cart) do

      existing_item = find_existing_item(cart, sku)

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `quantity` is used in arithmetic
      # VALIDATION: (`new_qty * product.unit_price`) without being validated
      # VALIDATION: as a positive integer at the function boundary. A string
      # VALIDATION: like "3" or a float 3.0 would pass the stock check guard
      # VALIDATION: if it is accidentally coerced, but then cause an ArithmeticError
      # VALIDATION: inside recalculate_totals/1, far from where the data entered.
      new_qty =
        cond do
          replace -> quantity
          existing_item -> existing_item.quantity + quantity
          true -> quantity
        end
      # VALIDATION: SMELL END

      updated_cart =
        if existing_item do
          update_item_quantity(cart, sku, new_qty, note)
        else
          append_item(cart, product, new_qty, note)
        end

      updated_cart = recalculate_totals(updated_cart)

      case Cart.save(updated_cart) do
        {:ok, saved_cart} ->
          Logger.info("Item added to cart #{cart_id}: sku=#{sku} qty=#{new_qty}")
          {:ok, saved_cart}

        {:error, _} ->
          {:error, :cart_save_failed}
      end
    end
  end

  @spec remove_item(String.t(), String.t()) :: {:ok, Cart.t()} | {:error, atom()}
  def remove_item(cart_id, sku) do
    with {:ok, cart} <- fetch_active_cart(cart_id) do
      updated_items = Enum.reject(cart.items, &(&1.sku == sku))
      updated_cart = %{cart | items: updated_items} |> recalculate_totals()
      Cart.save(updated_cart)
    end
  end

  @spec apply_coupon(String.t(), String.t()) :: {:ok, Cart.t()} | {:error, atom()}
  def apply_coupon(cart_id, coupon_code) do
    with {:ok, cart} <- fetch_active_cart(cart_id),
         {:ok, discount} <- CouponEngine.validate(coupon_code, cart) do
      updated_cart = %{cart | coupon_code: coupon_code, discount_amount: discount}
      Cart.save(recalculate_totals(updated_cart))
    end
  end

  @spec checkout(String.t(), Customer.t()) :: {:ok, map()} | {:error, atom()}
  def checkout(cart_id, customer) do
    with {:ok, cart} <- fetch_active_cart(cart_id),
         :ok <- validate_cart_not_empty(cart),
         :ok <- revalidate_stock(cart) do
      {:ok, %{cart: cart, customer: customer, ready: true}}
    end
  end

  # Private helpers

  defp fetch_active_cart(cart_id) do
    with {:ok, cart} <- Cart.fetch(cart_id) do
      if cart.status == :active, do: {:ok, cart}, else: {:error, :cart_inactive}
    end
  end

  defp check_stock_availability(product, qty) do
    if product.stock_qty >= qty, do: :ok, else: {:error, :insufficient_stock}
  end

  defp check_cart_capacity(%{items: items}) when length(items) >= @max_distinct_items,
    do: {:error, :cart_full}

  defp check_cart_capacity(_), do: :ok

  defp find_existing_item(cart, sku) do
    Enum.find(cart.items, &(&1.sku == sku))
  end

  defp update_item_quantity(cart, sku, new_qty, note) do
    items =
      Enum.map(cart.items, fn item ->
        if item.sku == sku do
          %{item | quantity: new_qty, note: note || item.note}
        else
          item
        end
      end)

    %{cart | items: items}
  end

  defp append_item(cart, product, qty, note) do
    new_item = %CartItem{
      sku: product.sku,
      name: product.name,
      quantity: qty,
      unit_price: product.unit_price,
      note: note
    }

    %{cart | items: [new_item | cart.items]}
  end

  defp recalculate_totals(cart) do
    subtotal =
      Enum.reduce(cart.items, 0, fn item, acc ->
        acc + item.quantity * item.unit_price
      end)

    %{cart | subtotal: subtotal, total: subtotal - Map.get(cart, :discount_amount, 0)}
  end

  defp validate_cart_not_empty(%{items: []}), do: {:error, :cart_empty}
  defp validate_cart_not_empty(_), do: :ok

  defp revalidate_stock(cart) do
    Enum.reduce_while(cart.items, :ok, fn item, _acc ->
      case ProductCatalog.fetch(item.sku) do
        {:ok, product} when product.stock_qty >= item.quantity -> {:cont, :ok}
        _ -> {:halt, {:error, :stock_changed}}
      end
    end)
  end
end
```
