```elixir
defmodule Ecommerce.DiscountUtils do
  @moduledoc """
  Coupon evaluation and discount calculation primitives for the e-commerce platform.
  """

  def apply_percentage(price_cents, pct) when pct >= 0 and pct <= 100 do
    discount = round(price_cents * pct / 100)
    max(0, price_cents - discount)
  end

  def apply_flat(price_cents, flat_cents) do
    max(0, price_cents - flat_cents)
  end

  def apply_bogo(items) do
    items
    |> Enum.sort_by(& &1.unit_price_cents, :desc)
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      if rem(idx, 2) == 1,
        do: %{item | unit_price_cents: 0},
        else: item
    end)
  end

  def coupon_valid?(%{expires_at: exp}) when not is_nil(exp) do
    DateTime.compare(exp, DateTime.utc_now()) == :gt
  end

  def coupon_valid?(_), do: true
end

defmodule Ecommerce.PricingHelpers do
  @moduledoc """
  Price computation helpers shared across e-commerce order modules via `use`.
  """

  @default_tax_rate 0.08

  defmacro __using__(_opts) do
    quote do
      import Ecommerce.DiscountUtils  # propagates discount dependency into every caller

      def line_total(item), do: item.quantity * item.unit_price_cents

      def cart_subtotal(items) do
        Enum.reduce(items, 0, fn item, acc -> acc + line_total(item) end)
      end

      def tax_amount(subtotal_cents, rate \\ unquote(@default_tax_rate)) do
        round(subtotal_cents * rate)
      end

      def shipping_cost(subtotal_cents) do
        cond do
          subtotal_cents >= 10_000 -> 0
          subtotal_cents >= 5_000  -> 499
          true                     -> 999
        end
      end

      def grand_total(subtotal_cents, shipping_cents, tax_cents) do
        subtotal_cents + shipping_cents + tax_cents
      end
    end
  end
end

defmodule Ecommerce.OrderProcessor do
  @moduledoc """
  Processes customer orders: applies coupons, calculates pricing, validates
  stock, and emits order-created events for downstream fulfillment.
  """

  use Ecommerce.PricingHelpers

  @fulfillable_statuses [:pending, :awaiting_payment]

  def process(cart, customer, opts \\ []) do
    coupon = opts[:coupon]

    with :ok              <- validate_cart(cart),
         {:ok, items}     <- apply_coupon(cart.items, coupon),
         {:ok, pricing}   <- compute_pricing(items),
         {:ok, order}     <- build_order(customer, items, pricing) do
      {:ok, order}
    end
  end

  def apply_coupon(items, nil), do: {:ok, items}

  def apply_coupon(items, coupon) do
    if coupon_valid?(coupon) do
      discounted =
        case coupon.type do
          :percentage -> Enum.map(items, fn i ->
              %{i | unit_price_cents: apply_percentage(i.unit_price_cents, coupon.value)}
            end)
          :flat       -> apply_flat_to_cart(items, coupon.value)
          :bogo       -> apply_bogo(items)
          _           -> items
        end

      {:ok, discounted}
    else
      {:error, :coupon_expired}
    end
  end

  def compute_pricing(items) do
    subtotal  = cart_subtotal(items)
    tax       = tax_amount(subtotal)
    shipping  = shipping_cost(subtotal)
    total     = grand_total(subtotal, shipping, tax)

    {:ok, %{subtotal: subtotal, tax: tax, shipping: shipping, total: total}}
  end

  def cancel(%{status: status} = order) when status in @fulfillable_statuses do
    {:ok, %{order | status: :cancelled, cancelled_at: DateTime.utc_now()}}
  end

  def cancel(_), do: {:error, :cannot_cancel}

  defp build_order(customer, items, pricing) do
    order = %{
      id:          order_id(),
      customer_id: customer.id,
      items:       items,
      subtotal:    pricing.subtotal,
      tax:         pricing.tax,
      shipping:    pricing.shipping,
      total:       pricing.total,
      status:      :pending,
      created_at:  DateTime.utc_now()
    }

    {:ok, order}
  end

  defp validate_cart(%{items: []}), do: {:error, :empty_cart}
  defp validate_cart(%{items: items}) when is_list(items), do: :ok
  defp validate_cart(_), do: {:error, :invalid_cart}

  defp apply_flat_to_cart(items, flat_cents) do
    total = cart_subtotal(items)
    if total <= flat_cents do
      Enum.map(items, &%{&1 | unit_price_cents: 0})
    else
      ratio = 1 - flat_cents / total
      Enum.map(items, fn i ->
        %{i | unit_price_cents: round(i.unit_price_cents * ratio)}
      end)
    end
  end

  defp order_id do
    :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false) |> then(&"ORD-#{&1}")
  end
end
```
