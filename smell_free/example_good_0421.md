# File: `example_good_421.md`

```elixir
defmodule Commerce.CartManager do
  @moduledoc """
  GenServer managing the lifecycle of shopping carts, including item
  additions, quantity updates, coupon application, and checkout
  readiness validation.

  Each cart is identified by a session-scoped key. Inactive carts
  are expired on a periodic sweep to prevent unbounded memory growth.
  """

  use GenServer

  @cart_ttl_s 3_600
  @sweep_interval_ms 300_000

  @type cart_key :: String.t()
  @type sku :: String.t()
  @type quantity :: pos_integer()
  @type amount_cents :: non_neg_integer()

  @type line_item :: %{sku: sku(), quantity: quantity(), unit_price_cents: amount_cents()}

  @type cart :: %{
          key: cart_key(),
          items: %{sku() => line_item()},
          coupon_code: String.t() | nil,
          discount_cents: non_neg_integer(),
          last_updated_at: integer()
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Adds `quantity` units of `sku` at `unit_price_cents` to the cart.
  Creates the cart if it does not yet exist.
  """
  @spec add_item(cart_key(), sku(), quantity(), amount_cents()) :: {:ok, cart()}
  def add_item(cart_key, sku, quantity, unit_price_cents)
      when is_binary(cart_key) and is_binary(sku) and
             is_integer(quantity) and quantity > 0 and
             is_integer(unit_price_cents) and unit_price_cents >= 0 do
    GenServer.call(__MODULE__, {:add_item, cart_key, sku, quantity, unit_price_cents})
  end

  @doc """
  Sets the quantity for an existing line item. Passing `0` removes the item.
  """
  @spec set_quantity(cart_key(), sku(), non_neg_integer()) ::
          {:ok, cart()} | {:error, :cart_not_found | :item_not_found}
  def set_quantity(cart_key, sku, quantity)
      when is_binary(cart_key) and is_binary(sku) and
             is_integer(quantity) and quantity >= 0 do
    GenServer.call(__MODULE__, {:set_quantity, cart_key, sku, quantity})
  end

  @doc """
  Applies a coupon code and discount amount to the cart.
  """
  @spec apply_coupon(cart_key(), String.t(), amount_cents()) ::
          {:ok, cart()} | {:error, :cart_not_found}
  def apply_coupon(cart_key, coupon_code, discount_cents)
      when is_binary(cart_key) and is_binary(coupon_code) and
             is_integer(discount_cents) and discount_cents >= 0 do
    GenServer.call(__MODULE__, {:apply_coupon, cart_key, coupon_code, discount_cents})
  end

  @doc """
  Returns the current cart state.
  """
  @spec get(cart_key()) :: {:ok, cart()} | {:error, :cart_not_found}
  def get(cart_key) when is_binary(cart_key) do
    GenServer.call(__MODULE__, {:get, cart_key})
  end

  @doc """
  Computes the current totals for a cart.
  """
  @spec totals(cart_key()) ::
          {:ok, %{subtotal_cents: amount_cents(), discount_cents: amount_cents(), total_cents: amount_cents()}}
          | {:error, :cart_not_found}
  def totals(cart_key) when is_binary(cart_key) do
    GenServer.call(__MODULE__, {:totals, cart_key})
  end

  @doc """
  Clears and removes a cart entirely.
  """
  @spec clear(cart_key()) :: :ok
  def clear(cart_key) when is_binary(cart_key) do
    GenServer.cast(__MODULE__, {:clear, cart_key})
  end

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{carts: %{}}}
  end

  @impl GenServer
  def handle_call({:add_item, key, sku, qty, price}, _from, state) do
    cart = get_or_create_cart(state, key)

    updated_cart =
      update_in(cart, [:items, sku], fn
        nil -> %{sku: sku, quantity: qty, unit_price_cents: price}
        existing -> %{existing | quantity: existing.quantity + qty}
      end)
      |> touch()

    {:reply, {:ok, updated_cart}, put_cart(state, key, updated_cart)}
  end

  @impl GenServer
  def handle_call({:set_quantity, key, sku, qty}, _from, state) do
    case Map.fetch(state.carts, key) do
      :error -> {:reply, {:error, :cart_not_found}, state}
      {:ok, cart} ->
        if not Map.has_key?(cart.items, sku) do
          {:reply, {:error, :item_not_found}, state}
        else
          updated = (if qty == 0, do: update_in(cart, [:items], &Map.delete(&1, sku)),
                                  else: put_in(cart, [:items, sku, :quantity], qty)) |> touch()
          {:reply, {:ok, updated}, put_cart(state, key, updated)}
        end
    end
  end

  @impl GenServer
  def handle_call({:apply_coupon, key, code, discount}, _from, state) do
    case Map.fetch(state.carts, key) do
      :error -> {:reply, {:error, :cart_not_found}, state}
      {:ok, cart} ->
        updated = %{cart | coupon_code: code, discount_cents: discount} |> touch()
        {:reply, {:ok, updated}, put_cart(state, key, updated)}
    end
  end

  @impl GenServer
  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.carts, key) do
      {:ok, cart} -> {:reply, {:ok, cart}, state}
      :error -> {:reply, {:error, :cart_not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:totals, key}, _from, state) do
    case Map.fetch(state.carts, key) do
      :error -> {:reply, {:error, :cart_not_found}, state}
      {:ok, cart} ->
        subtotal = cart.items |> Map.values() |> Enum.sum_by(&(&1.quantity * &1.unit_price_cents))
        total = max(subtotal - cart.discount_cents, 0)
        result = %{subtotal_cents: subtotal, discount_cents: cart.discount_cents, total_cents: total}
        {:reply, {:ok, result}, state}
    end
  end

  @impl GenServer
  def handle_cast({:clear, key}, state) do
    {:noreply, update_in(state, [:carts], &Map.delete(&1, key))}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - @cart_ttl_s
    live = Map.reject(state.carts, fn {_k, c} -> c.last_updated_at < cutoff end)
    schedule_sweep()
    {:noreply, %{state | carts: live}}
  end

  defp get_or_create_cart(state, key) do
    Map.get(state.carts, key, %{key: key, items: %{}, coupon_code: nil,
                                 discount_cents: 0, last_updated_at: now_s()})
  end

  defp put_cart(state, key, cart), do: put_in(state, [:carts, key], cart)
  defp touch(cart), do: %{cart | last_updated_at: now_s()}
  defp now_s, do: System.system_time(:second)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
