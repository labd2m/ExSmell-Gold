# Annotated Bad Example 28

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Catalog.ProductPricer`, `use Catalog.MarkupHelpers` directive
**Affected Functions:** `price_product/2`, `apply_promotion/2`, `bulk_price/2`, `render_price_tag/1`
**Explanation:** `Catalog.ProductPricer` uses `use Catalog.MarkupHelpers` to obtain margin and markup calculation utilities. However, `MarkupHelpers.__using__/1` also silently injects an alias for `Catalog.PromoEngine` and sets `@default_margin_pct` and `@default_vat_rate` module attributes in the calling module. A reader of `ProductPricer` sees no explicit declaration of these propagated dependencies. A plain `import Catalog.MarkupHelpers` would expose only the needed arithmetic helpers without the hidden alias and module attributes.

```elixir
defmodule Catalog.MarkupHelpers do
  @moduledoc """
  Pure arithmetic helpers for cost-to-price margin and markup calculations.
  All functions operate on integer cents to avoid floating-point drift.
  """

  def apply_margin(cost_cents, margin_pct) when is_integer(cost_cents) and is_number(margin_pct) do
    round(cost_cents / (1 - margin_pct / 100))
  end

  def apply_markup(cost_cents, markup_pct) when is_integer(cost_cents) and is_number(markup_pct) do
    round(cost_cents * (1 + markup_pct / 100))
  end

  def add_vat(price_cents, vat_rate) when is_integer(price_cents) and is_number(vat_rate) do
    round(price_cents * (1 + vat_rate))
  end

  def margin_from_cost_price(cost_cents, price_cents) when price_cents > 0 do
    Float.round((price_cents - cost_cents) / price_cents * 100, 2)
  end
  def margin_from_cost_price(_, _), do: 0.0

  def round_to_nearest(cents, step) when is_integer(cents) and is_integer(step) do
    round(cents / step) * step
  end

  def format_price(cents, symbol \\ "$") do
    "#{symbol}#{:erlang.float_to_binary(cents / 100, [{:decimals, 2}])}"
  end

  def discount_cents(price_cents, discount_pct) when is_integer(price_cents) do
    round(price_cents * discount_pct / 100)
  end

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 secretly propagates alias
  # Catalog.PromoEngine and two module attributes into every calling module.
  # The caller never requested PromoEngine, @default_margin_pct, or @default_vat_rate
  # as explicit dependencies; they are injected invisibly by the `use` directive.
  defmacro __using__(_opts) do
    quote do
      import Catalog.MarkupHelpers
      alias Catalog.PromoEngine

      @default_margin_pct 40
      @default_vat_rate   0.20
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Catalog.PromoEngine do
  @moduledoc "Evaluates promotional rules against a product and context (stub)."

  def applicable_promos(product_id, _context) do
    case product_id do
      id when is_binary(id) -> [%{type: :percentage, value: 10, code: "SALE10"}]
      _                     -> []
    end
  end

  def best_discount(promos, price_cents) when is_list(promos) do
    Enum.reduce(promos, 0, fn promo, best ->
      d = case promo.type do
        :percentage -> round(price_cents * promo.value / 100)
        :fixed      -> promo.value
        _           -> 0
      end
      max(d, best)
    end)
  end
end

defmodule Catalog.ProductPricer do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Catalog.MarkupHelpers` expands
  # __using__/1, silently making alias Catalog.PromoEngine and the module attributes
  # @default_margin_pct and @default_vat_rate available in this module without
  # any explicit declaration. A reader must inspect the library macro to discover
  # these hidden dependencies. `import Catalog.MarkupHelpers` would be sufficient.
  use Catalog.MarkupHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Calculates retail prices from supplier cost prices, applying margin targets,
  VAT, promotional discounts, and price rounding for the product catalogue.
  """

  defstruct [
    :product_id, :sku, :cost_cents, :base_price_cents,
    :vat_price_cents, :final_price_cents, :margin_pct,
    :discount_applied, :currency
  ]

  def price_product(%{id: id, cost_cents: cost, sku: sku} = _product, opts \\ []) do
    margin_pct  = opts[:margin_pct]  || @default_margin_pct
    vat_rate    = opts[:vat_rate]    || @default_vat_rate
    context     = opts[:context]     || %{}

    base_price  = apply_margin(cost, margin_pct)
    rounded     = round_to_nearest(base_price, 100)
    vat_price   = add_vat(rounded, vat_rate)

    promos    = PromoEngine.applicable_promos(id, context)
    discount  = PromoEngine.best_discount(promos, vat_price)
    final     = max(vat_price - discount, cost)

    %__MODULE__{
      product_id:       id,
      sku:              sku,
      cost_cents:       cost,
      base_price_cents: rounded,
      vat_price_cents:  vat_price,
      final_price_cents: final,
      margin_pct:       margin_from_cost_price(cost, final),
      discount_applied: discount,
      currency:         opts[:currency] || "USD"
    }
  end

  def apply_promotion(%__MODULE__{vat_price_cents: vat} = pricing, discount_pct) do
    d     = discount_cents(vat, discount_pct)
    final = vat - d
    %{pricing | final_price_cents: final, discount_applied: d}
  end

  def bulk_price(%__MODULE__{base_price_cents: base} = pricing, quantity) do
    discount_pct = cond do
      quantity >= 100 -> 20
      quantity >=  50 -> 15
      quantity >=  10 -> 10
      true            -> 0
    end
    apply_promotion(pricing, discount_pct)
  end

  def render_price_tag(%__MODULE__{} = p) do
    symbol = currency_symbol(p.currency)
    was    = if p.discount_applied > 0, do: " (was #{format_price(p.vat_price_cents, symbol)})", else: ""
    "#{format_price(p.final_price_cents, symbol)}#{was} | margin: #{p.margin_pct}%"
  end

  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol(_),     do: ""
end
```
