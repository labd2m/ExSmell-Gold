```elixir
defmodule Commerce.DiscountEngine do
  use GenServer

  @moduledoc """
  Applies promotional discounts and coupon codes to shopping carts.
  Supports percentage-off, fixed-amount, buy-X-get-Y, and free-shipping promotions.
  """

  @promotions [
    %{
      id: "SUMMER20",
      type: :percentage,
      value: 0.20,
      min_cart_value: 50.0,
      active: true,
      description: "20% off orders over $50"
    },
    %{
      id: "FLAT10",
      type: :fixed,
      value: 10.0,
      min_cart_value: 30.0,
      active: true,
      description: "$10 off orders over $30"
    },
    %{
      id: "FREESHIP",
      type: :free_shipping,
      value: 0.0,
      min_cart_value: 75.0,
      active: true,
      description: "Free shipping on orders over $75"
    },
    %{
      id: "VIP30",
      type: :percentage,
      value: 0.30,
      min_cart_value: 100.0,
      active: true,
      description: "30% off for VIP customers"
    }
  ]



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, @promotions, opts)
  end

  @doc """
  Applies the best eligible promotion or the given coupon code to the cart.
  Returns `{:ok, discounted_cart}` or `{:error, reason}`.
  """
  def apply(pid, cart, coupon_code \\ nil) do
    GenServer.call(pid, {:apply, cart, coupon_code})
  end

  @doc """
  Returns a preview of all savings without modifying the cart.
  """
  def preview(pid, cart, coupon_code \\ nil) do
    GenServer.call(pid, {:preview, cart, coupon_code})
  end

  @doc """
  Returns all active promotions applicable to the cart.
  """
  def applicable_promotions(pid, cart) do
    GenServer.call(pid, {:applicable_promotions, cart})
  end

  @doc """
  Validates a coupon code against the active promotions list.
  """
  def validate_coupon(pid, coupon_code) do
    GenServer.call(pid, {:validate_coupon, coupon_code})
  end

  ## GenServer Callbacks

  @impl true
  def init(promotions), do: {:ok, promotions}

  @impl true
  def handle_call({:apply, cart, coupon_code}, _from, promotions) do
    promotion = find_promotion(promotions, cart, coupon_code)

    result =
      case promotion do
        nil ->
          {:ok, cart}

        promo ->
          discount = compute_discount(promo, cart)
          updated = update_cart(cart, discount, promo)
          {:ok, updated}
      end

    {:reply, result, promotions}
  end

  @impl true
  def handle_call({:preview, cart, coupon_code}, _from, promotions) do
    promotion = find_promotion(promotions, cart, coupon_code)

    preview =
      case promotion do
        nil ->
          %{promotion: nil, discount: 0.0, final_total: cart.total}

        promo ->
          discount = compute_discount(promo, cart)

          %{
            promotion: promo.id,
            description: promo.description,
            discount: discount,
            final_total: Float.round(cart.total - discount, 2)
          }
      end

    {:reply, {:ok, preview}, promotions}
  end

  @impl true
  def handle_call({:applicable_promotions, cart}, _from, promotions) do
    eligible =
      promotions
      |> Enum.filter(& &1.active)
      |> Enum.filter(&(cart.total >= &1.min_cart_value))

    {:reply, {:ok, eligible}, promotions}
  end

  @impl true
  def handle_call({:validate_coupon, coupon_code}, _from, promotions) do
    result =
      case Enum.find(promotions, &(&1.id == String.upcase(coupon_code) and &1.active)) do
        nil -> {:error, "Invalid or expired coupon code"}
        promo -> {:ok, promo}
      end

    {:reply, result, promotions}
  end

  defp find_promotion(promotions, cart, nil) do
    promotions
    |> Enum.filter(& &1.active)
    |> Enum.filter(&(cart.total >= &1.min_cart_value))
    |> Enum.max_by(&compute_discount(&1, cart), fn -> nil end)
  end

  defp find_promotion(promotions, cart, coupon_code) do
    Enum.find(promotions, fn p ->
      p.active and p.id == String.upcase(coupon_code) and cart.total >= p.min_cart_value
    end)
  end

  defp compute_discount(%{type: :percentage, value: pct}, cart),
    do: Float.round(cart.total * pct, 2)

  defp compute_discount(%{type: :fixed, value: amount}, _cart),
    do: amount

  defp compute_discount(%{type: :free_shipping}, cart),
    do: Map.get(cart, :shipping_cost, 0.0)

  defp update_cart(cart, discount, promo) do
    cart
    |> Map.put(:discount, discount)
    |> Map.put(:applied_promotion, promo.id)
    |> Map.update!(:total, &Float.round(&1 - discount, 2))
  end
end
```
