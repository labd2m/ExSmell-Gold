```elixir
defmodule CartAgent do
  @moduledoc "Shared Agent for shopping cart session state."

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{carts: %{}, promo_uses: %{}} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

defmodule CartItemAdder do
  @moduledoc "Adds and updates items in a customer shopping cart."

  require Logger

  @max_quantity 99

  def add(agent, cart_id, %{sku: sku, quantity: qty, unit_price: price} = item)
      when qty > 0 and qty <= @max_quantity do
    Agent.update(agent, fn state ->
      cart = Map.get(state.carts, cart_id, %{id: cart_id, line_items: [], promo_code: nil, created_at: DateTime.utc_now()})

      existing_index = Enum.find_index(cart.line_items, &(&1.sku == sku))

      updated_items =
        if existing_index do
          List.update_at(cart.line_items, existing_index, fn li ->
            new_qty = min(li.quantity + qty, @max_quantity)
            %{li | quantity: new_qty}
          end)
        else
          line_item = %{
            sku: sku,
            quantity: qty,
            unit_price: price,
            name: Map.get(item, :name, sku),
            added_at: DateTime.utc_now()
          }

          cart.line_items ++ [line_item]
        end

      updated_cart = %{cart | line_items: updated_items, updated_at: DateTime.utc_now()}
      %{state | carts: Map.put(state.carts, cart_id, updated_cart)}
    end)

    Logger.debug("Added #{qty}x #{sku} to cart #{cart_id}")
    :ok
  end

  def add(_agent, _cart_id, _item), do: {:error, :invalid_item}

  def remove(agent, cart_id, sku) do
    Agent.update(agent, fn state ->
      case Map.fetch(state.carts, cart_id) do
        :error -> state
        {:ok, cart} ->
          updated = %{cart | line_items: Enum.reject(cart.line_items, &(&1.sku == sku))}
          %{state | carts: Map.put(state.carts, cart_id, updated)}
      end
    end)
  end
end
defmodule CartPromoApplier do
  @moduledoc "Applies promotional codes to carts."

  require Logger

  @valid_promos %{
    "SAVE10" => %{type: :percent, value: 10},
    "FLAT5" => %{type: :flat, value: 5.0},
    "SUMMER20" => %{type: :percent, value: 20}
  }

  def apply_code(agent, cart_id, code) do
    promo = Map.get(@valid_promos, code)
    already_used = Agent.get(agent, fn state -> Map.get(state.promo_uses, code, 0) >= 1000 end)

    cond do
      is_nil(promo) -> {:error, :invalid_promo_code}
      already_used -> {:error, :promo_exhausted}
      true ->
        Agent.update(agent, fn state ->
          case Map.fetch(state.carts, cart_id) do
            :error ->
              state

            {:ok, cart} ->
              updated_cart = %{cart | promo_code: code, promo: promo, updated_at: DateTime.utc_now()}

              %{
                state
                | carts: Map.put(state.carts, cart_id, updated_cart),
                  promo_uses: Map.update(state.promo_uses, code, 1, &(&1 + 1))
              }
          end
        end)

        Logger.info("Applied promo #{code} to cart #{cart_id}")
        :ok
    end
  end
end
defmodule CartCheckout do
  @moduledoc "Processes a cart into a placed order."

  require Logger

  def checkout(agent, cart_id) do
    cart = Agent.get(agent, fn state -> Map.get(state.carts, cart_id) end)

    cond do
      is_nil(cart) ->
        {:error, :cart_not_found}

      cart.line_items == [] ->
        {:error, :empty_cart}

      true ->
        subtotal = Enum.reduce(cart.line_items, 0.0, fn li, acc -> acc + li.unit_price * li.quantity end)

        discount =
          case cart[:promo] do
            %{type: :percent, value: pct} -> Float.round(subtotal * pct / 100, 2)
            %{type: :flat, value: flat} -> flat
            nil -> 0.0
          end

        order = %{
          id: "ORD-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16()),
          cart_id: cart_id,
          line_items: cart.line_items,
          subtotal: subtotal,
          discount: discount,
          total: Float.round(subtotal - discount, 2),
          placed_at: DateTime.utc_now()
        }

        Agent.update(agent, fn state ->
          %{state | carts: Map.delete(state.carts, cart_id)}
        end)

        Logger.info("Checked out cart #{cart_id} → order #{order.id}")
        {:ok, order}
    end
  end
end
defmodule CartInspector do
  @moduledoc "Provides read-only views into a cart for display and debugging."

  def totals(agent, cart_id) do
    Agent.get(agent, fn state ->
      case Map.get(state.carts, cart_id) do
        nil ->
          nil

        cart ->
          subtotal = Enum.reduce(cart.line_items, 0.0, fn li, acc -> acc + li.unit_price * li.quantity end)
          item_count = Enum.reduce(cart.line_items, 0, fn li, acc -> acc + li.quantity end)

          %{
            cart_id: cart_id,
            item_count: item_count,
            line_count: length(cart.line_items),
            subtotal: Float.round(subtotal, 2),
            promo_code: cart[:promo_code]
          }
      end
    end)
  end
end
```
