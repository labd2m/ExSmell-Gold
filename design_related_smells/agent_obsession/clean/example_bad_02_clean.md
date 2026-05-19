```elixir
defmodule CartSession do
  @moduledoc """
  Manages a shopping cart session for a customer.
  """

  def new do
    Agent.start_link(fn -> %{items: [], meta: %{}} end)
  end

  def add_item(pid, sku, quantity) do
    Agent.update(pid, fn state ->
      item = %{sku: sku, quantity: quantity, added_at: DateTime.utc_now()}
      Map.update!(state, :items, fn items -> [item | items] end)
    end)
  end

  def get_items(pid) do
    Agent.get(pid, fn state -> state.items end)
  end

  def item_count(pid) do
    Agent.get(pid, fn state -> length(state.items) end)
  end
end

defmodule DiscountEngine do
  @moduledoc """
  Applies discount coupons and promotional rules to a cart.
  """

  @valid_coupons %{"SAVE10" => 0.10, "SAVE20" => 0.20, "FREESHIP" => 0.0}

  def apply_coupon(pid, code, customer_id) do
    case Map.fetch(@valid_coupons, code) do
      {:ok, rate} ->
        Agent.update(pid, fn state ->
          discount = %{code: code, rate: rate, applied_by: customer_id}
          put_in(state, [:meta, :discount], discount)
        end)
        {:ok, rate}
      :error ->
        {:error, :invalid_coupon}
    end
  end

  def discount_rate(pid) do
    Agent.get(pid, fn state ->
      get_in(state, [:meta, :discount, :rate]) || 0.0
    end)
  end
end

defmodule CheckoutService do
  @moduledoc """
  Finalizes the checkout process and records order status.
  """

  def finalize(pid, payment_method) do
    items = Agent.get(pid, fn state -> state.items end)

    if Enum.empty?(items) do
      {:error, :empty_cart}
    else
      Agent.update(pid, fn state ->
        checkout_info = %{
          status: :completed,
          payment_method: payment_method,
          finalized_at: DateTime.utc_now()
        }
        put_in(state, [:meta, :checkout], checkout_info)
      end)
      {:ok, :order_placed}
    end
  end

  def order_status(pid) do
    Agent.get(pid, fn state ->
      get_in(state, [:meta, :checkout, :status]) || :pending
    end)
  end
end

defmodule OrderSummary do
  @moduledoc """
  Builds a display summary of the current cart and order state.
  """

  def build(pid) do
    state = Agent.get(pid, fn s -> s end)

    discount_rate = get_in(state, [:meta, :discount, :rate]) || 0.0
    checkout = get_in(state, [:meta, :checkout]) || %{}

    subtotal =
      state.items
      |> Enum.reduce(0, fn %{quantity: q}, acc -> acc + q end)

    %{
      item_count: length(state.items),
      subtotal_units: subtotal,
      discount_applied: discount_rate > 0,
      discount_rate: discount_rate,
      order_status: Map.get(checkout, :status, :pending),
      payment_method: Map.get(checkout, :payment_method)
    }
  end
end
```
