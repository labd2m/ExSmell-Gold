```elixir
defmodule Catalog.ProductVariant do
  @moduledoc "Represents a purchasable variant of a product (size, colour, etc.)."

  defstruct [
    :id,
    :product_id,
    :sku,
    :label,
    :price,
    :currency,
    :stock_level,
    :reorder_point,
    :clearance,
    :clearance_markdown_pct,
    :volume_breaks,
    :weight_g,
    :active
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      product_id: "PROD-8810",
      sku: "WDGT-BLU-LG",
      label: "Widget Blue Large",
      price: Decimal.new("49.95"),
      currency: "USD",
      stock_level: 250,
      reorder_point: 50,
      clearance: false,
      clearance_markdown_pct: Decimal.new("0.00"),
      volume_breaks: [{10, Decimal.new("0.05")}, {50, Decimal.new("0.12")}, {100, Decimal.new("0.18")}],
      weight_g: 320,
      active: true
    }
  end

  def base_price(%__MODULE__{price: p}), do: p

  def volume_tier(%__MODULE__{volume_breaks: breaks}, quantity) do
    breaks
    |> Enum.filter(fn {min_qty, _} -> quantity >= min_qty end)
    |> Enum.max_by(fn {min_qty, _} -> min_qty end, fn -> {0, Decimal.new("0.00")} end)
    |> elem(1)
  end

  def is_on_clearance?(%__MODULE__{clearance: true}), do: true
  def is_on_clearance?(_), do: false

  def markdown_rate(%__MODULE__{clearance_markdown_pct: pct}), do: pct

  def in_stock?(%__MODULE__{stock_level: lvl, reorder_point: rp}), do: lvl > rp

  def display_label(%__MODULE__{label: l, sku: s}), do: "#{l} (#{s})"
end

defmodule Catalog.PricingEngine do
  @moduledoc """
  Computes final customer-facing prices for product variants, applying
  volume discounts, clearance markdowns, and currency formatting.
  """

  alias Catalog.ProductVariant
  require Logger

  @doc """
  Generates a price sheet for the given variant IDs at the requested quantity.
  Returns a list of maps with original and final prices.
  """
  def generate_price_sheet(variant_ids, quantity) do
    Enum.map(variant_ids, fn id ->
      variant = ProductVariant.get!(id)
      final   = apply_tier_pricing(id, quantity)

      %{
        variant_id: id,
        sku:        variant.sku,
        label:      ProductVariant.display_label(variant),
        in_stock:   ProductVariant.in_stock?(variant),
        original:   ProductVariant.base_price(variant),
        quantity:   quantity,
        final:      final,
        currency:   variant.currency
      }
    end)
  end

  defp apply_tier_pricing(variant_id, quantity) do
    variant       = ProductVariant.get!(variant_id)
    base          = ProductVariant.base_price(variant)
    volume_disc   = ProductVariant.volume_tier(variant, quantity)
    on_clearance  = ProductVariant.is_on_clearance?(variant)
    markdown      = ProductVariant.markdown_rate(variant)

    price_after_volume =
      Decimal.sub(base, Decimal.mult(base, volume_disc))

    final =
      if on_clearance do
        clearance_price = Decimal.sub(base, Decimal.mult(base, markdown))
        Decimal.min(price_after_volume, clearance_price)
      else
        price_after_volume
      end

    Decimal.round(final, 2)
  end

  defp format_price(amount, currency) do
    "#{currency} #{Decimal.to_string(amount)}"
  end
end
```
