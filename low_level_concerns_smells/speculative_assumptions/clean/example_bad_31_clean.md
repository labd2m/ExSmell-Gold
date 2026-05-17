```elixir
defmodule Inventory.SkuParser do
  @moduledoc """
  Decodes product SKU strings into structured attribute maps.

  SKU format: {CATEGORY}-{BRAND_CODE}-{SIZE}-{COLOR_CODE}-{VARIANT}
  Example:    ELC-APL-M-BLK-001

  Used by the warehouse management system to identify and route products
  during picking and packing.
  """

  require Logger

  @sku_pattern ~r/^([A-Z]{2,4})-([A-Z0-9]{2,6})-([A-Z0-9]{1,4})-([A-Z]{3})-(\d{3})$/

  @color_codes %{
    "BLK" => "Black",
    "WHT" => "White",
    "RED" => "Red",
    "BLU" => "Blue",
    "GRN" => "Green",
    "GRY" => "Gray",
    "YLW" => "Yellow",
    "PNK" => "Pink",
    "ORG" => "Orange",
    "PRP" => "Purple"
  }

  @category_codes %{
    "ELC" => "Electronics",
    "CLT" => "Clothing",
    "FRN" => "Furniture",
    "SPT" => "Sports",
    "TYS" => "Toys",
    "BKS" => "Books",
    "KCH" => "Kitchen"
  }

  def decode_attributes(sku) when is_binary(sku) do
    captures = Regex.run(@sku_pattern, sku)

    {category_code, brand_code, size, color_code, variant} =
      if captures do
        {
          Enum.at(captures, 1),
          Enum.at(captures, 2),
          Enum.at(captures, 3),
          Enum.at(captures, 4),
          Enum.at(captures, 5)
        }
      else
        parts = String.split(sku, "-")

        {
          Enum.at(parts, 0),
          Enum.at(parts, 1),
          Enum.at(parts, 2),
          Enum.at(parts, 3),
          Enum.at(parts, 4)
        }
      end

    %{
      sku:           sku,
      category_code: category_code,
      category:      Map.get(@category_codes, category_code, "Unknown"),
      brand_code:    brand_code,
      size:          size,
      color_code:    color_code,
      color:         Map.get(@color_codes, color_code, "Unknown"),
      variant:       variant
    }
  end

  def decode_attributes(_), do: {:error, :invalid_sku}

  def valid_sku?(sku) when is_binary(sku) do
    Regex.match?(@sku_pattern, sku)
  end

  def valid_sku?(_), do: false

  def same_category?(sku1, sku2) do
    attrs1 = decode_attributes(sku1)
    attrs2 = decode_attributes(sku2)
    is_map(attrs1) and is_map(attrs2) and attrs1.category_code == attrs2.category_code
  end

  def group_by_category(skus) when is_list(skus) do
    skus
    |> Enum.map(&decode_attributes/1)
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(& &1.category)
  end

  def describe(%{sku: sku, category: cat, brand_code: brand, size: size, color: color}) do
    "#{sku} — #{cat} | Brand: #{brand} | Size: #{size} | Color: #{color}"
  end

  def describe(_), do: "Unknown SKU"

  def filter_by_color(skus, color_code) do
    skus
    |> Enum.map(&decode_attributes/1)
    |> Enum.filter(fn
      %{color_code: cc} -> cc == color_code
      _                 -> false
    end)
  end

  def variants_for(skus, category_code, brand_code) do
    skus
    |> Enum.map(&decode_attributes/1)
    |> Enum.filter(fn
      %{category_code: cat, brand_code: brand} ->
        cat == category_code and brand == brand_code

      _ ->
        false
    end)
    |> Enum.map(& &1.variant)
    |> Enum.uniq()
  end
end
```
