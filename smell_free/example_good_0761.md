```elixir
defmodule MyApp.Commerce.CheckoutTaxResolver do
  @moduledoc """
  Resolves the correct tax jurisdiction and rates for a checkout session
  based on the buyer's shipping address and the product tax categories
  in the cart. Tax determination follows a three-step process: address
  normalisation, jurisdiction lookup, and rate application. The result
  is a line-item-level tax breakdown suitable for both display and
  regulatory reporting.
  """

  alias MyApp.Billing.TaxCalculator
  alias MyApp.Commerce.{Cart, CartItem}

  @type tax_line :: %{
          item_id: String.t(),
          sku: String.t(),
          subtotal_cents: pos_integer(),
          tax_cents: non_neg_integer(),
          tax_rate_pct: float(),
          tax_category: String.t()
        }

  @type tax_summary :: %{
          lines: [tax_line()],
          total_tax_cents: non_neg_integer(),
          jurisdiction: String.t()
        }

  @doc """
  Resolves taxes for all items in `cart` shipping to `address`.
  Returns a structured summary with per-line tax amounts.
  """
  @spec resolve(Cart.t(), map()) :: {:ok, tax_summary()} | {:error, term()}
  def resolve(%Cart{} = cart, address) when is_map(address) do
    with {:ok, normalised_address} <- normalise_address(address) do
      lines = Enum.map(cart.items, &resolve_item_tax(&1, normalised_address))
      total = Enum.sum_by(lines, & &1.tax_cents)
      jurisdiction = format_jurisdiction(normalised_address)

      {:ok, %{lines: lines, total_tax_cents: total, jurisdiction: jurisdiction}}
    end
  end

  @doc "Returns `true` when any tax applies to the given address and cart."
  @spec taxable?(Cart.t(), map()) :: boolean()
  def taxable?(%Cart{} = cart, address) do
    case resolve(cart, address) do
      {:ok, %{total_tax_cents: total}} -> total > 0
      {:error, _} -> false
    end
  end

  @spec resolve_item_tax(CartItem.t(), map()) :: tax_line()
  defp resolve_item_tax(item, address) do
    subtotal = item.unit_price_cents * item.quantity
    tax_result = TaxCalculator.calculate(subtotal, address, item.tax_category)

    %{
      item_id: item.id,
      sku: item.sku,
      subtotal_cents: subtotal,
      tax_cents: tax_result.tax_amount_cents,
      tax_rate_pct: tax_result.total_tax_bps / 100.0,
      tax_category: item.tax_category
    }
  end

  @spec normalise_address(map()) :: {:ok, map()} | {:error, :invalid_address}
  defp normalise_address(address) do
    country = Map.get(address, :country) || Map.get(address, "country")

    if is_binary(country) and byte_size(country) == 2 do
      normalised = %{
        country: String.upcase(country),
        region: address[:region] || address["region"],
        postal_code: address[:postal_code] || address["postal_code"]
      }

      {:ok, normalised}
    else
      {:error, :invalid_address}
    end
  end

  @spec format_jurisdiction(map()) :: String.t()
  defp format_jurisdiction(%{country: country, region: nil}), do: country
  defp format_jurisdiction(%{country: country, region: region}), do: "#{country}-#{region}"
end
```
