```elixir
defmodule Ecommerce.PricingEngine do
  @moduledoc """
  Computes prices for products, factoring in promotions, customer tiers,
  and regional tax rules.
  """

  alias Ecommerce.Repo
  alias Ecommerce.Schema.{Product, Promotion, TaxRule, CustomerTier}

  @doc """
  Returns the effective price for a product for a given customer.

  ## Arguments

    * `product_id` — ID of the product.
    * `customer_id` — ID of the purchasing customer.
    * `opts` — Keyword list of options.

  ## Options

    * `:region` — ISO region code used to apply tax rules. Defaults to `"US-CA"`.
    * `:promo_code` — Promotional code to apply if valid.
    * `:as_cents` — When `true`, returns the total as an integer in the
      smallest currency unit (cents). Defaults to `false`.
    * `:with_breakdown` — When `true`, returns a map:
      `%{base: Decimal, discount: Decimal, tax: Decimal, total: Decimal}`.
      Overrides `:as_cents`.

  ## Examples

      iex> get_price(10, 55)
      #Decimal<49.99>

      iex> get_price(10, 55, as_cents: true)
      4999

      iex> get_price(10, 55, with_breakdown: true)
      %{base: #Decimal<59.99>, discount: #Decimal<10.00>, tax: #Decimal<3.92>, total: #Decimal<53.91>}

  """

  def get_price(product_id, customer_id, opts \\ []) when is_list(opts) do
    region = Keyword.get(opts, :region, "US-CA")
    promo_code = Keyword.get(opts, :promo_code)

    product = Repo.get!(Product, product_id)
    tier = Repo.get_by(CustomerTier, customer_id: customer_id)
    tax_rule = Repo.get_by(TaxRule, region: region) || %TaxRule{rate: Decimal.new("0.0")}
    promotion = promo_code && Repo.get_by(Promotion, code: promo_code, active: true)

    base = product.price
    discount = compute_discount(base, tier, promotion)
    pre_tax = Decimal.sub(base, discount)
    tax = Decimal.mult(pre_tax, tax_rule.rate) |> Decimal.round(2)
    total = Decimal.add(pre_tax, tax)

    cond do
      opts[:with_breakdown] == true ->
        %{base: base, discount: discount, tax: tax, total: total}

      opts[:as_cents] == true ->
        total |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()

      true ->
        total
    end
  end

  defp compute_discount(base, tier, promotion) do
    tier_discount = tier && Decimal.mult(base, tier.discount_rate) || Decimal.new(0)
    promo_discount = promotion && Decimal.mult(base, promotion.discount_rate) || Decimal.new(0)

    [tier_discount, promo_discount]
    |> Enum.max_by(&Decimal.to_float/1)
  end

  @doc """
  Computes the total price for a list of `{product_id, quantity}` line items.
  """
  def cart_total(line_items, customer_id, opts \\ []) do
    Enum.reduce(line_items, Decimal.new(0), fn {product_id, quantity}, acc ->
      unit_price = get_price(product_id, customer_id, opts)
      line_total = Decimal.mult(unit_price, quantity)
      Decimal.add(acc, line_total)
    end)
  end

  @doc """
  Validates a promo code and returns the discount rate if applicable.
  """
  def validate_promo(code) do
    case Repo.get_by(Promotion, code: code, active: true) do
      nil ->
        {:error, :invalid_code}

      %Promotion{expires_at: exp} = promo when not is_nil(exp) ->
        if DateTime.compare(DateTime.utc_now(), exp) == :gt do
          {:error, :expired}
        else
          {:ok, promo.discount_rate}
        end

      %Promotion{} = promo ->
        {:ok, promo.discount_rate}
    end
  end
end
```
