```elixir
defmodule Commerce.CartManager do
  @moduledoc """
  Manages shopping cart lifecycle for anonymous and authenticated sessions.
  Handles item additions, quantity updates, coupon application, and cart expiry.
  """

  use GenServer

  alias Commerce.{CartItem, PricingEngine, CouponValidator}

  @type cart_id :: String.t()
  @type item_id :: String.t()
  @type coupon_code :: String.t()
  @type cart :: %{
    id: cart_id(),
    session_id: String.t(),
    items: [CartItem.t()],
    coupon: coupon_code() | nil,
    discount_cents: non_neg_integer(),
    expires_at: DateTime.t()
  }
  @type state :: %{carts: %{cart_id() => cart()}}

  @cart_ttl_seconds 3600
  @sweep_interval_ms 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{carts: %{}}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec create(String.t()) :: {:ok, cart()}
  def create(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:create, session_id})
  end

  @spec add_item(cart_id(), CartItem.t()) :: {:ok, cart()} | {:error, :not_found | String.t()}
  def add_item(cart_id, %CartItem{} = item) when is_binary(cart_id) do
    GenServer.call(__MODULE__, {:add_item, cart_id, item})
  end

  @spec update_quantity(cart_id(), item_id(), pos_integer()) ::
          {:ok, cart()} | {:error, :not_found | :item_not_found}
  def update_quantity(cart_id, item_id, quantity)
      when is_binary(cart_id) and is_binary(item_id) and is_integer(quantity) and quantity > 0 do
    GenServer.call(__MODULE__, {:update_quantity, cart_id, item_id, quantity})
  end

  @spec remove_item(cart_id(), item_id()) :: {:ok, cart()} | {:error, :not_found}
  def remove_item(cart_id, item_id) when is_binary(cart_id) and is_binary(item_id) do
    GenServer.call(__MODULE__, {:remove_item, cart_id, item_id})
  end

  @spec apply_coupon(cart_id(), coupon_code()) ::
          {:ok, cart()} | {:error, :not_found | :invalid_coupon | String.t()}
  def apply_coupon(cart_id, coupon_code) when is_binary(cart_id) and is_binary(coupon_code) do
    GenServer.call(__MODULE__, {:apply_coupon, cart_id, coupon_code})
  end

  @spec get(cart_id()) :: {:ok, cart()} | {:error, :not_found}
  def get(cart_id) when is_binary(cart_id) do
    GenServer.call(__MODULE__, {:get, cart_id})
  end

  @spec subtotal(cart()) :: non_neg_integer()
  def subtotal(%{items: items}) do
    Enum.reduce(items, 0, fn item, acc -> acc + item.unit_price_cents * item.quantity end)
  end

  @spec total(cart()) :: non_neg_integer()
  def total(%{discount_cents: discount} = cart) do
    max(subtotal(cart) - discount, 0)
  end

  @impl GenServer
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:create, session_id}, _from, state) do
    cart = build_cart(session_id)
    {:reply, {:ok, cart}, %{state | carts: Map.put(state.carts, cart.id, cart)}}
  end

  def handle_call({:add_item, cart_id, item}, _from, state) do
    update_cart(state, cart_id, &add_or_merge_item(&1, item))
  end

  def handle_call({:update_quantity, cart_id, item_id, quantity}, _from, state) do
    update_cart(state, cart_id, &set_item_quantity(&1, item_id, quantity))
  end

  def handle_call({:remove_item, cart_id, item_id}, _from, state) do
    update_cart(state, cart_id, &drop_item(&1, item_id))
  end

  def handle_call({:apply_coupon, cart_id, coupon_code}, _from, state) do
    with {:ok, cart} <- fetch_cart(state, cart_id),
         {:ok, discount_cents} <- CouponValidator.validate(coupon_code, subtotal(cart)) do
      updated = %{cart | coupon: coupon_code, discount_cents: discount_cents}
      new_state = %{state | carts: Map.put(state.carts, cart_id, updated)}
      {:reply, {:ok, updated}, new_state}
    else
      {:error, :not_found} = err -> {:reply, err, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, cart_id}, _from, state) do
    {:reply, fetch_cart(state, cart_id), state}
  end

  @impl GenServer
  def handle_info(:sweep_expired, state) do
    now = DateTime.utc_now()
    active = Map.reject(state.carts, fn {_, cart} -> DateTime.before?(cart.expires_at, now) end)
    schedule_sweep()
    {:noreply, %{state | carts: active}}
  end

  @spec update_cart(state(), cart_id(), (cart() -> {:ok, cart()} | {:error, term()})) ::
          {:reply, {:ok, cart()} | {:error, term()}, state()}
  defp update_cart(state, cart_id, transform_fn) do
    case fetch_cart(state, cart_id) do
      {:ok, cart} ->
        case transform_fn.(cart) do
          {:ok, updated} ->
            new_state = %{state | carts: Map.put(state.carts, cart_id, updated)}
            {:reply, {:ok, updated}, new_state}
          {:error, _} = err ->
            {:reply, err, state}
        end
      {:error, :not_found} = err ->
        {:reply, err, state}
    end
  end

  @spec fetch_cart(state(), cart_id()) :: {:ok, cart()} | {:error, :not_found}
  defp fetch_cart(state, cart_id) do
    case Map.get(state.carts, cart_id) do
      nil -> {:error, :not_found}
      cart -> {:ok, cart}
    end
  end

  @spec add_or_merge_item(cart(), CartItem.t()) :: {:ok, cart()}
  defp add_or_merge_item(cart, item) do
    updated_items =
      case Enum.find_index(cart.items, &(&1.id == item.id)) do
        nil ->
          [item | cart.items]

        idx ->
          List.update_at(cart.items, idx, fn existing ->
            %{existing | quantity: existing.quantity + item.quantity}
          end)
      end

    {:ok, %{cart | items: updated_items}}
  end

  @spec set_item_quantity(cart(), item_id(), pos_integer()) ::
          {:ok, cart()} | {:error, :item_not_found}
  defp set_item_quantity(cart, item_id, quantity) do
    case Enum.find_index(cart.items, &(&1.id == item_id)) do
      nil ->
        {:error, :item_not_found}

      idx ->
        updated = List.update_at(cart.items, idx, &%{&1 | quantity: quantity})
        {:ok, %{cart | items: updated}}
    end
  end

  @spec drop_item(cart(), item_id()) :: {:ok, cart()}
  defp drop_item(cart, item_id) do
    {:ok, %{cart | items: Enum.reject(cart.items, &(&1.id == item_id))}}
  end

  @spec build_cart(String.t()) :: cart()
  defp build_cart(session_id) do
    %{
      id: generate_id(),
      session_id: session_id,
      items: [],
      coupon: nil,
      discount_cents: 0,
      expires_at: DateTime.add(DateTime.utc_now(), @cart_ttl_seconds, :second)
    }
  end

  @spec generate_id() :: String.t()
  defp generate_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
end
```
