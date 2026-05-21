# Annotated Bad Example 16: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Inventory.SkuBuilder.build_sku/3`
- **Affected function(s)**: `build_sku/3`
- **Short explanation**: The function accepts a `variant` parameter and calls `to_string/1` on it to compose the SKU string. No guard clause restricts the type of `variant`. While `String.Chars` is implemented for integers, floats, and atoms, it is not implemented for maps, lists, or tuples. More importantly, calling `to_string/1` on a float produces a non-deterministic scientific notation representation (e.g., `"1.0e0"`), and calling it on an integer or atom may silently generate a syntactically valid but semantically incorrect SKU. The function's domain clearly expects a human-readable variant code (a binary), but this is never enforced.

## Code

```elixir
defmodule Inventory.SkuBuilder do
  @moduledoc """
  Constructs and parses SKU (Stock Keeping Unit) codes for the inventory system.
  SKUs follow the pattern: `{CATEGORY}-{PRODUCT_CODE}-{VARIANT}`, e.g. `ELEC-TV55-BLK`.

  Used during product creation, variant import, and barcode generation workflows.
  """

  @sku_separator "-"
  @max_category_length 6
  @max_product_code_length 8
  @max_variant_length 6

  @doc """
  Builds a canonical SKU string from its three components.

  ## Parameters
    - `category`: A short uppercase category code, e.g. `"ELEC"`.
    - `product_code`: A product-level code, e.g. `"TV55"`.
    - `variant`: A variant discriminator, e.g. `"BLK"` or `"XL"`.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `to_string/1` is called on the `variant`
  # parameter without any guard clause restricting its type. The `String.Chars`
  # protocol is not implemented for `Map`, `List`, or `Tuple`, so passing those
  # types will raise `Protocol.UndefinedError` at runtime. Passing a `Float` will
  # silently produce `"1.5e0"`, and passing an `Integer` will produce a numeric
  # string — both are syntactically valid SKUs but semantically meaningless as
  # variant codes. The function should require `variant` to be a binary or atom.
  def build_sku(category, product_code, variant)
      when is_binary(category) and is_binary(product_code) do
    normalized_variant = to_string(variant) |> String.upcase() |> String.trim()

    [
      String.upcase(category),
      String.upcase(product_code),
      normalized_variant
    ]
    |> Enum.join(@sku_separator)
  end
  # VALIDATION: SMELL END

  @doc """
  Parses a SKU string into its three components.
  Returns `{:ok, {category, product_code, variant}}` or `{:error, :invalid_sku}`.
  """
  def parse_sku(sku) when is_binary(sku) do
    case String.split(sku, @sku_separator, parts: 3) do
      [category, product_code, variant] ->
        {:ok, {category, product_code, variant}}

      _ ->
        {:error, :invalid_sku}
    end
  end

  @doc """
  Validates that each component of a SKU is within the allowed length.
  Returns `:ok` or `{:error, {component, reason}}`.
  """
  def validate_sku_components(category, product_code, variant)
      when is_binary(category) and is_binary(product_code) and is_binary(variant) do
    cond do
      String.length(category) > @max_category_length ->
        {:error, {:category, :too_long}}

      String.length(product_code) > @max_product_code_length ->
        {:error, {:product_code, :too_long}}

      String.length(variant) > @max_variant_length ->
        {:error, {:variant, :too_long}}

      not Regex.match?(~r/^[A-Z0-9]+$/, category) ->
        {:error, {:category, :invalid_chars}}

      not Regex.match?(~r/^[A-Z0-9]+$/, product_code) ->
        {:error, {:product_code, :invalid_chars}}

      not Regex.match?(~r/^[A-Z0-9]+$/, variant) ->
        {:error, {:variant, :invalid_chars}}

      true ->
        :ok
    end
  end

  @doc """
  Generates a list of all variant SKUs for a product given a list of variant codes.
  """
  def expand_variants(category, product_code, variants)
      when is_binary(category) and is_binary(product_code) and is_list(variants) do
    Enum.map(variants, fn v -> build_sku(category, product_code, v) end)
  end

  @doc """
  Extracts the category portion from a fully formed SKU string.
  """
  def sku_category(sku) when is_binary(sku) do
    sku
    |> String.split(@sku_separator)
    |> List.first()
  end

  @doc """
  Returns true if two SKUs belong to the same product family
  (same category and product code, different variant).
  """
  def same_product_family?(sku_a, sku_b)
      when is_binary(sku_a) and is_binary(sku_b) do
    with {:ok, {cat_a, code_a, _}} <- parse_sku(sku_a),
         {:ok, {cat_b, code_b, _}} <- parse_sku(sku_b) do
      cat_a == cat_b and code_a == code_b
    else
      _ -> false
    end
  end
end
```
