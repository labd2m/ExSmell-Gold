```elixir
defmodule MyApp.CartAgent do
  @moduledoc """
  Manages per-user shopping cart state including item management,
  discount application, tax calculation, and checkout submission.
  """

  use Agent

  alias MyApp.{Repo, PricingService, TaxCalculator, OrderService, InventoryChecker}
  alias MyApp.Cart.{CartItem, Cart}

  @cart_ttl_seconds 1_800

  def start_link(_opts) do
    Agent.start_link(fn -> %{carts: %{}} end, name: __MODULE__)
  end

  def get_cart(user_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.carts, user_id) end)
  end

  def list_carts do
    Agent.get(__MODULE__, fn state -> Map.values(state.carts) end)
  end

  def add_item(user_id, sku, quantity) do
    Agent.get_and_update(__MODULE__, fn state ->
      cart = Map.get(state.carts, user_id, new_cart(user_id))

      case InventoryChecker.available?(sku, quantity) do
        false ->
          {{:error, :insufficient_stock}, state}

        true ->
          unit_price = PricingService.get_price(sku, user_id)

          item = %CartItem{
            sku: sku,
            quantity: quantity,
            unit_price_cents: unit_price,
            added_at: DateTime.utc_now()
          }

          existing_idx = Enum.find_index(cart.items, &(&1.sku == sku))

          updated_items =
            if existing_idx do
              List.update_at(cart.items, existing_idx, fn existing ->
                %{existing | quantity: existing.quantity + quantity}
              end)
            else
              [item | cart.items]
            end

          subtotal = Enum.reduce(updated_items, 0, &(&1.quantity * &1.unit_price_cents + &2))
          tax = TaxCalculator.calculate(subtotal, cart.shipping_country)

          updated_cart = %{
            cart
            | items: updated_items,
              subtotal_cents: subtotal,
              tax_cents: tax,
              total_cents: subtotal + tax,
              updated_at: DateTime.utc_now()
          }

          new_state = put_in(state, [:carts, user_id], updated_cart)
          {{:ok, updated_cart}, new_state}
      end
    end)
  end

  def remove_item(user_id, sku) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.carts, user_id) do
        :error ->
          {{:error, :cart_not_found}, state}

        {:ok, cart} ->
          updated_items = Enum.reject(cart.items, &(&1.sku == sku))
          subtotal = Enum.reduce(updated_items, 0, &(&1.quantity * &1.unit_price_cents + &2))
          tax = TaxCalculator.calculate(subtotal, cart.shipping_country)

          updated_cart = %{
            cart
            | items: updated_items,
              subtotal_cents: subtotal,
              tax_cents: tax,
              total_cents: subtotal + tax,
              updated_at: DateTime.utc_now()
          }

          {{:ok, updated_cart}, put_in(state, [:carts, user_id], updated_cart)}
      end
    end)
  end

  def apply_discount(user_id, promo_code, discount_percent) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.carts, user_id) do
        :error ->
          {{:error, :cart_not_found}, state}

        {:ok, %{discount_code: existing}} when not is_nil(existing) ->
          {{:error, :discount_already_applied}, state}

        {:ok, cart} ->
          if discount_percent < 0 or discount_percent > 100 do
            {{:error, :invalid_discount}, state}
          else
            discount_cents = trunc(cart.subtotal_cents * discount_percent / 100)
            discounted_subtotal = cart.subtotal_cents - discount_cents
            tax = TaxCalculator.calculate(discounted_subtotal, cart.shipping_country)

            updated_cart = %{
              cart
              | discount_code: promo_code,
                discount_cents: discount_cents,
                tax_cents: tax,
                total_cents: discounted_subtotal + tax,
                updated_at: DateTime.utc_now()
            }

            {{:ok, updated_cart}, put_in(state, [:carts, user_id], updated_cart)}
          end
      end
    end)
  end

  def checkout(user_id, payment_method_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, cart} <- Map.fetch(state.carts, user_id),
           false <- Enum.empty?(cart.items),
           {:ok, order} <- OrderService.submit(cart, payment_method_id) do
        new_state = %{state | carts: Map.delete(state.carts, user_id)}
        {{:ok, order}, new_state}
      else
        :error -> {{:error, :cart_not_found}, state}
        true -> {{:error, :empty_cart}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  end

  def expire_stale_carts do
    cutoff = DateTime.add(DateTime.utc_now(), -@cart_ttl_seconds, :second)

    Agent.update(__MODULE__, fn state ->
      fresh =
        state.carts
        |> Enum.reject(fn {_uid, cart} -> DateTime.compare(cart.updated_at, cutoff) == :lt end)
        |> Map.new()

      %{state | carts: fresh}
    end)
  end

  defp new_cart(user_id) do
    %Cart{
      user_id: user_id,
      items: [],
      subtotal_cents: 0,
      tax_cents: 0,
      discount_cents: 0,
      total_cents: 0,
      discount_code: nil,
      shipping_country: "US",
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
```
