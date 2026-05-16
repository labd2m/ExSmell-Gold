```elixir
defmodule Ecommerce.CartCheckout do
  @moduledoc """
  Processes shopping cart checkout: validates the cart, applies coupons,
  computes the order total, and prepares the checkout summary for payment.
  """

  require Logger

  @supported_currencies ~w(USD EUR GBP BRL AUD)
  @max_items_per_cart   100

  @type checkout_summary :: %{
          order_id: String.t(),
          customer_id: String.t(),
          currency: String.t(),
          subtotal: float(),
          discount: float(),
          tax: float(),
          total: float(),
          item_count: integer(),
          coupon_applied: String.t() | nil,
          created_at: DateTime.t()
        }

  @spec process(map(), map()) ::
          {:ok, checkout_summary()} | {:error, String.t()}
  def process(cart, store_config) do
    items       = cart[:items]
    coupon_code = cart[:coupon_code]
    customer_id = cart[:customer_id]
    currency    = cart[:currency]

    with :ok <- validate_customer(customer_id),
         :ok <- validate_currency(currency),
         :ok <- validate_items(items) do
      tax_rate  = get_tax_rate(currency, store_config)
      subtotal  = compute_subtotal(items)
      discount  = resolve_discount(coupon_code, subtotal, store_config)
      taxable   = subtotal - discount
      tax       = Float.round(taxable * tax_rate, 2)
      total     = Float.round(taxable + tax, 2)

      summary = %{
        order_id: generate_order_id(),
        customer_id: customer_id,
        currency: currency,
        subtotal: subtotal,
        discount: discount,
        tax: tax,
        total: total,
        item_count: length(items),
        coupon_applied: if(discount > 0, do: coupon_code),
        created_at: DateTime.utc_now()
      }

      Logger.info("Cart checkout processed",
        order_id: summary.order_id,
        customer_id: customer_id,
        currency: currency,
        total: total,
        coupon: coupon_code
      )

      {:ok, summary}
    end
  end

  # ── Computation ─────────────────────────────────────────────────────────────

  defp compute_subtotal(items) do
    items
    |> Enum.reduce(0.0, fn item, acc ->
      acc + item.unit_price * item.quantity
    end)
    |> Float.round(2)
  end

  defp resolve_discount(nil, _subtotal, _config), do: 0.0

  defp resolve_discount(coupon_code, subtotal, config) do
    coupons = Map.get(config, :coupons, %{})

    case Map.get(coupons, coupon_code) do
      nil ->
        Logger.warning("Unknown coupon code: #{coupon_code}")
        0.0

      %{type: :percentage, value: pct} ->
        Float.round(subtotal * (pct / 100), 2)

      %{type: :fixed, value: amount} ->
        min(Float.round(amount, 2), subtotal)
    end
  end

  defp get_tax_rate(currency, config) do
    config
    |> Map.get(:tax_rates, %{})
    |> Map.get(currency, 0.0)
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_customer(nil), do: {:error, "Customer ID is required"}
  defp validate_customer(_),   do: :ok

  defp validate_currency(nil), do: {:error, "Currency is required"}

  defp validate_currency(c) when c in @supported_currencies, do: :ok

  defp validate_currency(c),
    do: {:error, "Unsupported currency: #{c}. Supported: #{Enum.join(@supported_currencies, ", ")}"}

  defp validate_items(nil), do: {:error, "Cart items are required"}
  defp validate_items([]),  do: {:error, "Cart must contain at least one item"}

  defp validate_items(items) when length(items) > @max_items_per_cart,
    do: {:error, "Cart exceeds maximum of #{@max_items_per_cart} items"}

  defp validate_items(_), do: :ok

  defp generate_order_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
```
