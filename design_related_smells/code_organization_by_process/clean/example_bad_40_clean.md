```elixir
defmodule Commerce.OrderTotalCalculator do
  use GenServer

  @moduledoc """
  Computes order totals including subtotal, taxes, shipping, discounts,
  and final payable amounts during the checkout process.
  """

  @min_order_amount 0.01
  @max_coupon_discount 0.50

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Calculates the final order total for a list of `items`.
  Each item: `%{price: float, quantity: int, taxable: bool}`.
  Returns `{:ok, total_map}` or `{:error, reason}`.
  """
  def calculate(pid, items, opts \\ []) do
    GenServer.call(pid, {:calculate, items, opts})
  end

  @doc """
  Applies `coupon` to an existing `total_map` returned by `calculate/3`.
  Returns an updated `total_map` with coupon applied.
  """
  def apply_coupon(pid, total_map, coupon) do
    GenServer.call(pid, {:apply_coupon, total_map, coupon})
  end

  @doc "Returns a detailed cost breakdown for a list of items."
  def breakdown(pid, items) do
    GenServer.call(pid, {:breakdown, items})
  end

  @doc "Returns `{:ok, items}` or `{:error, invalid_items}` after validation."
  def validate_items(pid, items) do
    GenServer.call(pid, {:validate_items, items})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:validate_items, items}, _from, state) do
    invalid =
      Enum.filter(items, fn item ->
        not (is_number(item[:price]) and item[:price] >= @min_order_amount and
               is_integer(item[:quantity]) and item[:quantity] > 0)
      end)

    result =
      if invalid == [],
        do: {:ok, items},
        else: {:error, {:invalid_items, invalid}}

    {:reply, result, state}
  end

  def handle_call({:calculate, items, opts}, _from, state) do
    tax_rate      = Keyword.get(opts, :tax_rate, 0.0)
    shipping_cost = Keyword.get(opts, :shipping_cost, 0.0)

    subtotal =
      Enum.reduce(items, 0.0, fn item, acc ->
        acc + item.price * item.quantity
      end)

    taxable_subtotal =
      Enum.reduce(items, 0.0, fn item, acc ->
        if Map.get(item, :taxable, true),
          do: acc + item.price * item.quantity,
          else: acc
      end)

    tax   = Float.round(taxable_subtotal * tax_rate, 2)
    total = Float.round(subtotal + tax + shipping_cost, 2)

    result = %{
      subtotal:      Float.round(subtotal, 2),
      taxable_base:  Float.round(taxable_subtotal, 2),
      tax:           tax,
      shipping:      Float.round(shipping_cost, 2),
      discount:      0.0,
      total:         total
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:apply_coupon, total_map, coupon}, _from, state) do
    discount_amount =
      case coupon.type do
        :percentage ->
          pct     = min(coupon.value, @max_coupon_discount)
          Float.round(total_map.subtotal * pct, 2)

        :fixed ->
          min(coupon.value, total_map.subtotal)

        _ ->
          0.0
      end

    new_total    = Float.round(max(total_map.total - discount_amount, 0.0), 2)
    updated_map  = %{total_map | discount: discount_amount, total: new_total}

    {:reply, {:ok, updated_map}, state}
  end

  def handle_call({:breakdown, items}, _from, state) do
    lines =
      Enum.map(items, fn item ->
        %{
          description: Map.get(item, :name, "Item"),
          unit_price:  item.price,
          quantity:    item.quantity,
          line_total:  Float.round(item.price * item.quantity, 2),
          taxable:     Map.get(item, :taxable, true)
        }
      end)

    {:reply, {:ok, lines}, state}
  end

end
```
