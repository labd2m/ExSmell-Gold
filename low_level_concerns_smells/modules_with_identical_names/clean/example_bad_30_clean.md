```elixir
# ── file: lib/shop/cart_manager.ex ──────────────────────────────────────────


defmodule Shop.CartManager do
  @moduledoc """
  Manages customer shopping carts: adding, removing, and updating items.
  Defined in `lib/shop/cart_manager.ex`.
  """

  alias Shop.{CartStore, ProductCatalog, PricingEngine}

  @max_items_per_cart 50
  @cart_ttl_seconds 86_400

  @type cart_id :: String.t()
  @type sku :: String.t()
  @type quantity :: pos_integer()

  @type cart_item :: %{
    sku: sku(),
    name: String.t(),
    quantity: quantity(),
    unit_price: Decimal.t(),
    subtotal: Decimal.t()
  }

  @type cart :: %{
    id: cart_id(),
    session_id: String.t(),
    items: [cart_item()],
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @doc "Add a product to the cart, incrementing quantity if already present."
  @spec add_item(cart_id(), sku(), quantity()) ::
          {:ok, cart()} | {:error, String.t()}
  def add_item(cart_id, sku, qty \\ 1) when qty > 0 do
    with {:ok, cart} <- get_or_create(cart_id),
         :ok <- check_cart_capacity(cart),
         {:ok, product} <- ProductCatalog.fetch(sku),
         :ok <- check_stock(product, qty) do
      updated_items = upsert_item(cart.items, product, qty)
      save_cart(cart, updated_items)
    end
  end

  @doc "Remove a product from the cart entirely."
  @spec remove_item(cart_id(), sku()) :: {:ok, cart()} | {:error, String.t()}
  def remove_item(cart_id, sku) do
    with {:ok, cart} <- CartStore.fetch(cart_id) do
      updated_items = Enum.reject(cart.items, &(&1.sku == sku))
      save_cart(cart, updated_items)
    else
      :not_found -> {:error, "Cart not found: #{cart_id}"}
    end
  end

  @doc "Set the exact quantity for a cart item."
  @spec update_quantity(cart_id(), sku(), quantity()) ::
          {:ok, cart()} | {:error, String.t()}
  def update_quantity(cart_id, sku, new_qty) when new_qty > 0 do
    with {:ok, cart} <- CartStore.fetch(cart_id),
         {:ok, product} <- ProductCatalog.fetch(sku),
         :ok <- check_stock(product, new_qty) do
      updated_items =
        Enum.map(cart.items, fn
          %{sku: ^sku} = item ->
            %{item | quantity: new_qty, subtotal: Decimal.mult(item.unit_price, new_qty)}

          item ->
            item
        end)

      save_cart(cart, updated_items)
    end
  end

  def update_quantity(_cart_id, _sku, qty) when qty <= 0 do
    {:error, "Quantity must be positive"}
  end

  @doc "Remove all items from a cart."
  @spec clear(cart_id()) :: {:ok, cart()} | {:error, String.t()}
  def clear(cart_id) do
    with {:ok, cart} <- CartStore.fetch(cart_id) do
      save_cart(cart, [])
    else
      :not_found -> {:error, "Cart not found: #{cart_id}"}
    end
  end

  @doc "Return a pricing summary for checkout display."
  @spec checkout_summary(cart_id()) :: {:ok, map()} | {:error, String.t()}
  def checkout_summary(cart_id) do
    with {:ok, cart} <- CartStore.fetch(cart_id) do
      subtotal = Enum.reduce(cart.items, Decimal.new(0), &Decimal.add(&2, &1.subtotal))
      {:ok, applied} = PricingEngine.apply_promotions(cart)

      {:ok,
       %{
         items: cart.items,
         subtotal: subtotal,
         discount: applied.discount,
         tax: applied.tax,
         total: Decimal.sub(Decimal.add(subtotal, applied.tax), applied.discount)
       }}
    else
      :not_found -> {:error, "Cart not found: #{cart_id}"}
    end
  end

  defp get_or_create(cart_id) do
    case CartStore.fetch(cart_id) do
      {:ok, cart} ->
        {:ok, cart}

      :not_found ->
        now = DateTime.utc_now()
        cart = %{id: cart_id, session_id: cart_id, items: [], created_at: now, updated_at: now}
        CartStore.save(cart)
    end
  end

  defp check_cart_capacity(%{items: items}) do
    if length(items) < @max_items_per_cart,
      do: :ok,
      else: {:error, "Cart is full (max #{@max_items_per_cart} items)"}
  end

  defp check_stock(%{stock_level: sl}, qty) when sl >= qty, do: :ok
  defp check_stock(%{name: name}, _qty), do: {:error, "Insufficient stock for #{name}"}

  defp upsert_item(items, product, qty) do
    if existing = Enum.find(items, &(&1.sku == product.sku)) do
      new_qty = existing.quantity + qty
      Enum.map(items, fn
        %{sku: s} = item when s == product.sku ->
          %{item | quantity: new_qty, subtotal: Decimal.mult(item.unit_price, new_qty)}
        item -> item
      end)
    else
      unit_price = Decimal.new(product.price_cents) |> Decimal.div(100)
      new_item = %{
        sku: product.sku,
        name: product.name,
        quantity: qty,
        unit_price: unit_price,
        subtotal: Decimal.mult(unit_price, qty)
      }
      [new_item | items]
    end
  end

  defp save_cart(cart, items) do
    updated = %{cart | items: items, updated_at: DateTime.utc_now()}
    CartStore.save(updated, ttl: @cart_ttl_seconds)
  end
end


# ── file: lib/shop/cart_manager_expiry.ex ─────────────────────────────────────────────────────


defmodule Shop.CartManager do
  @moduledoc """
  Cart expiry and abandonment tracking helpers.
  """

  alias Shop.CartStore
  alias Shop.AbandonmentMailer

  @abandoned_threshold_hours 24
  @expiry_threshold_hours 72

  @doc "Mark all carts idle for more than the abandonment threshold."
  @spec mark_abandoned() :: {:ok, non_neg_integer()}
  def mark_abandoned do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@abandoned_threshold_hours * 3600, :second)

    carts = CartStore.all(updated_before: cutoff, status: :active)

    Enum.each(carts, fn cart ->
      CartStore.update(cart.id, %{status: :abandoned})
      AbandonmentMailer.send_recovery(cart)
    end)

    {:ok, length(carts)}
  end

  @doc "Purge carts that have exceeded the expiry threshold."
  @spec purge_expired() :: {:ok, non_neg_integer()}
  def purge_expired do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@expiry_threshold_hours * 3600, :second)

    carts = CartStore.all(updated_before: cutoff)
    Enum.each(carts, &CartStore.delete(&1.id))
    {:ok, length(carts)}
  end

  @doc "Return count of carts by status for the operations dashboard."
  @spec cart_counts() :: map()
  def cart_counts do
    CartStore.all()
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, carts} -> {status, length(carts)} end)
    |> Map.new()
  end
end

```
