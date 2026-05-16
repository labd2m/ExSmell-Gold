```elixir
defmodule MyApp.Pricing.Calculator do
  @moduledoc """
  Computes pricing for orders, subscriptions, and one-off charges.
  Applies dynamic discount rules, tax rates by jurisdiction, and
  promotional codes. Used by the checkout and quoting engines.
  """

  alias MyApp.Pricing.DiscountEngine
  alias MyApp.Pricing.TaxRateStore
  alias MyApp.Pricing.PromoCode

  @default_currency "BRL"
  @rounding_mode :half_up
  @rounding_scale 2

  def line_item(product_id, unit_price, quantity, opts \\ []) do
    discount = Keyword.get(opts, :discount, Decimal.new(0))
    subtotal = Decimal.mult(unit_price, Decimal.new(quantity))
    net = Decimal.sub(subtotal, discount)

    %{
      product_id: product_id,
      unit_price: unit_price,
      quantity: quantity,
      subtotal: subtotal,
      discount: discount,
      net: net
    }
  end

  def compute(line_items, opts \\ []) when is_list(opts) do
    breakdown = Keyword.get(opts, :breakdown, :total)
    currency = Keyword.get(opts, :currency, @default_currency)
    promo_code = Keyword.get(opts, :promo_code)
    jurisdiction = Keyword.get(opts, :jurisdiction, "BR-SP")

    subtotal =
      Enum.reduce(line_items, Decimal.new(0), fn item, acc ->
        Decimal.add(acc, item.net)
      end)

    {discounted_subtotal, applied_promos} =
      if promo_code do
        case PromoCode.apply(promo_code, subtotal, line_items) do
          {:ok, result} ->
            {result.final_subtotal, [result.promo]}

          {:error, _} ->
            {subtotal, []}
        end
      else
        {subtotal, []}
      end

    tax_rate = TaxRateStore.rate(jurisdiction, currency)
    tax_amount = Decimal.mult(discounted_subtotal, tax_rate) |> round_decimal()
    total = Decimal.add(discounted_subtotal, tax_amount) |> round_decimal()

    case breakdown do
      :total ->
        total

      :summary ->
        {discounted_subtotal, tax_amount, total}

      :detailed ->
        %{
          currency: currency,
          line_items: line_items,
          subtotal: subtotal,
          applied_promos: applied_promos,
          discounted_subtotal: discounted_subtotal,
          tax: %{
            jurisdiction: jurisdiction,
            rate: tax_rate,
            amount: tax_amount
          },
          total: total
        }
    end
  end

  def apply_global_discount(line_items, rate) when is_float(rate) do
    Enum.map(line_items, fn item ->
      discount = Decimal.mult(item.net, Decimal.from_float(rate))
      %{item | discount: Decimal.add(item.discount, discount), net: Decimal.sub(item.net, discount)}
    end)
  end

  def valid_promo?(code) do
    case PromoCode.lookup(code) do
      {:ok, promo} -> promo.active and not PromoCode.expired?(promo)
      _ -> false
    end
  end

  defp round_decimal(value) do
    Decimal.round(value, @rounding_scale, @rounding_mode)
  end
end
```
