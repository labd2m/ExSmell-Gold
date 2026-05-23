## Smell Metadata

- **Smell:** Shotgun Surgery
- **Expected Smell Location:** Functions `price_multiplier/1`, `requires_inspection?/1` in `Inventory.PricingEngine`; `listing_label/1`, `eligible_for_sale?/1` in `Inventory.ListingPolicy`; `insurance_covered?/1`, `write_down_rate/1` in `Inventory.AssetAccounting`
- **Affected Functions:** See above (6 functions across 3 modules)
- **Explanation:** Adding a new item condition (e.g., `:damaged`) requires scattered changes across three separate inventory modules. Pricing adjustments, listing eligibility, and accounting write-down rules are each independently defined per condition type with no centralized condition registry.

```elixir
defmodule Inventory.PricingEngine do
  @moduledoc """
  Calculates sale prices for inventory items by applying condition-specific
  multipliers to the item's base or RRP value.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: This is a smell because adding a new condition (e.g., :damaged)
  # VALIDATION: requires new clauses in price_multiplier/1 and requires_inspection?/1
  # VALIDATION: here, AND independent changes in Inventory.ListingPolicy and
  # VALIDATION: Inventory.AssetAccounting.

  @spec price_multiplier(atom()) :: float()
  def price_multiplier(:new),         do: 1.00
  def price_multiplier(:used),        do: 0.65
  def price_multiplier(:refurbished), do: 0.80

  @spec requires_inspection?(atom()) :: boolean()
  def requires_inspection?(:new),         do: false
  def requires_inspection?(:used),        do: true
  def requires_inspection?(:refurbished), do: true

  # VALIDATION: SMELL END

  def calculate_price(item) do
    multiplier = price_multiplier(item.condition)
    base       = item.rrp || item.cost_price

    adjusted = base * multiplier

    if requires_inspection?(item.condition) and not item.inspected? do
      {:hold, :pending_inspection}
    else
      {:ok, Float.round(adjusted, 2)}
    end
  end

  def bulk_price_list(items) do
    items
    |> Enum.filter(& &1.active?)
    |> Enum.map(fn item ->
      case calculate_price(item) do
        {:ok, price}  -> %{sku: item.sku, price: price, condition: item.condition}
        {:hold, _}    -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end

defmodule Inventory.ListingPolicy do
  @moduledoc """
  Governs whether items in each condition state may be actively listed
  for sale, and how they should be labelled in customer-facing channels.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: listing_label/1 and eligible_for_sale?/1 require independent new
  # VALIDATION: clauses per condition type, separate from PricingEngine and
  # VALIDATION: AssetAccounting.

  @spec listing_label(atom()) :: String.t()
  def listing_label(:new),         do: "New"
  def listing_label(:used),        do: "Pre-Owned"
  def listing_label(:refurbished), do: "Certified Refurbished"

  @spec eligible_for_sale?(atom()) :: boolean()
  def eligible_for_sale?(:new),         do: true
  def eligible_for_sale?(:used),        do: true
  def eligible_for_sale?(:refurbished), do: true

  # VALIDATION: SMELL END

  def build_listing(item) do
    condition = item.condition

    if not eligible_for_sale?(condition) do
      {:error, :not_eligible}
    else
      case Inventory.PricingEngine.calculate_price(item) do
        {:ok, price} ->
          {:ok, %{
            sku:             item.sku,
            title:           item.name,
            condition_label: listing_label(condition),
            price:           price,
            stock:           item.quantity_available,
            images:          item.image_urls
          }}

        {:hold, reason} ->
          {:error, reason}
      end
    end
  end
end

defmodule Inventory.AssetAccounting do
  @moduledoc """
  Applies condition-appropriate write-down rates and determines insurance
  coverage eligibility for asset valuation and risk management reporting.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: insurance_covered?/1 and write_down_rate/1 must also be independently
  # VALIDATION: updated per new condition type, adding yet another scattered change.

  @spec insurance_covered?(atom()) :: boolean()
  def insurance_covered?(:new),         do: true
  def insurance_covered?(:used),        do: true
  def insurance_covered?(:refurbished), do: false

  @spec write_down_rate(atom()) :: float()
  def write_down_rate(:new),         do: 0.00
  def write_down_rate(:used),        do: 0.35
  def write_down_rate(:refurbished), do: 0.20

  # VALIDATION: SMELL END

  def asset_value(item) do
    written_down = item.cost_price * (1 - write_down_rate(item.condition))
    Float.round(written_down, 2)
  end

  def generate_asset_report(inventory_items) do
    inventory_items
    |> Enum.group_by(& &1.condition)
    |> Enum.map(fn {condition, items} ->
      total_cost     = Enum.sum(Enum.map(items, & &1.cost_price))
      total_value    = items |> Enum.map(&asset_value/1) |> Enum.sum()
      covered_items  = Enum.count(items, fn i -> insurance_covered?(i.condition) end)

      %{
        condition:       condition,
        count:           length(items),
        total_cost:      Float.round(total_cost, 2),
        written_value:   Float.round(total_value, 2),
        write_down:      Float.round(total_cost - total_value, 2),
        insured_count:   covered_items
      }
    end)
  end
end
```
