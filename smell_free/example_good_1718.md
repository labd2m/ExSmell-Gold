```elixir
defmodule Commerce.CartManager do
  @moduledoc """
  GenServer managing the lifecycle and state of a single shopping cart.

  Each cart runs as an independent supervised process identified by
  a session token. Cart state includes line items, applied coupons,
  and a configurable expiry deadline enforced via scheduled messages.
  """

  use GenServer, restart: :transient

  require Logger

  alias Commerce.LineItem
  alias Commerce.CouponValidator
  alias Commerce.PricingEngine

  @cart_ttl_ms 60 * 60 * 1_000

  @type session_id :: String.t()
  @type sku :: String.t()
  @type quantity :: pos_integer()

  @type state :: %{
          session_id: session_id(),
          items: %{sku() => LineItem.t()},
          coupon_code: String.t() | nil,
          expires_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc "Adds or increments a line item in the cart."
  @spec add_item(session_id(), sku(), quantity()) ::
          {:ok, LineItem.t()} | {:error, :cart_not_found | :invalid_sku}
  def add_item(session_id, sku, qty)
      when is_binary(session_id) and is_binary(sku) and is_integer(qty) and qty > 0 do
    GenServer.call(via(session_id), {:add_item, sku, qty})
  catch
    :exit, _ -> {:error, :cart_not_found}
  end

  @doc "Removes a SKU from the cart entirely."
  @spec remove_item(session_id(), sku()) :: :ok | {:error, :cart_not_found}
  def remove_item(session_id, sku) when is_binary(session_id) and is_binary(sku) do
    GenServer.call(via(session_id), {:remove_item, sku})
  catch
    :exit, _ -> {:error, :cart_not_found}
  end

  @doc "Applies a coupon code to the cart."
  @spec apply_coupon(session_id(), String.t()) ::
          {:ok, :applied} | {:error, :invalid_coupon | :cart_not_found}
  def apply_coupon(session_id, code) when is_binary(session_id) and is_binary(code) do
    GenServer.call(via(session_id), {:apply_coupon, code})
  catch
    :exit, _ -> {:error, :cart_not_found}
  end

  @doc "Returns the current cart summary including totals."
  @spec summary(session_id()) :: {:ok, map()} | {:error, :cart_not_found}
  def summary(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :summary)
  catch
    :exit, _ -> {:error, :cart_not_found}
  end

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.send_after(self(), :expire, @cart_ttl_ms)

    state = %{
      session_id: session_id,
      items: %{},
      coupon_code: nil,
      expires_at: DateTime.add(DateTime.utc_now(), @cart_ttl_ms, :millisecond)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:add_item, sku, qty}, _from, state) do
    case PricingEngine.fetch_price(sku) do
      {:ok, unit_price_cents} ->
        item = %LineItem{sku: sku, quantity: qty, unit_price_cents: unit_price_cents}
        updated_items = Map.update(state.items, sku, item, &%{&1 | quantity: &1.quantity + qty})
        {:reply, {:ok, Map.fetch!(updated_items, sku)}, %{state | items: updated_items}}

      {:error, :not_found} ->
        {:reply, {:error, :invalid_sku}, state}
    end
  end

  def handle_call({:remove_item, sku}, _from, state) do
    {:reply, :ok, %{state | items: Map.delete(state.items, sku)}}
  end

  def handle_call({:apply_coupon, code}, _from, state) do
    case CouponValidator.validate(code) do
      {:ok, _discount} ->
        {:reply, {:ok, :applied}, %{state | coupon_code: code}}

      {:error, :invalid} ->
        {:reply, {:error, :invalid_coupon}, state}
    end
  end

  def handle_call(:summary, _from, state) do
    subtotal = Enum.reduce(state.items, 0, fn {_, item}, acc ->
      acc + item.quantity * item.unit_price_cents
    end)

    {:reply, {:ok, %{items: state.items, subtotal_cents: subtotal, coupon: state.coupon_code}}, state}
  end

  @impl GenServer
  def handle_info(:expire, state) do
    Logger.debug("Cart #{state.session_id} expired.")
    {:stop, :normal, state}
  end

  defp via(session_id) do
    {:via, Registry, {Commerce.CartRegistry, session_id}}
  end
end
```
