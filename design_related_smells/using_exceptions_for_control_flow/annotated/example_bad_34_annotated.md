# Annotated Example 34

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `ProductCatalogue.fetch/1` (library) and `CartManager.add_item/3` (client)
- **Affected function(s):** `ProductCatalogue.fetch/1`, `CartManager.add_item/3`
- **Short explanation:** `ProductCatalogue.fetch/1` raises exceptions for discontinued products, unlisted SKUs, and region-restricted items. These are foreseeable outcomes every time a customer adds a product to a cart — for example, a product may have been discontinued between a user browsing and clicking "add". Without a tuple-returning variant, `CartManager.add_item/3` is forced to use `try...rescue` for routine product-availability logic.

```elixir
defmodule ProductCatalogue do
  @moduledoc """
  Provides product details and availability from the central product catalogue.
  Used by cart, checkout, and search services.
  """

  defmodule ProductNotFoundError do
    defexception [:message, :sku]
  end

  defmodule DiscontinuedProductError do
    defexception [:message, :sku, :discontinued_at]
  end

  defmodule RegionRestrictedError do
    defexception [:message, :sku, :region, :allowed_regions]
  end

  defmodule InvalidSkuError do
    defexception [:message, :sku]
  end

  @sku_regex ~r/^[A-Z]{3}-\d{4,6}$/

  @catalogue %{
    "WDG-10001" => %{
      sku: "WDG-10001",
      name: "Premium Widget Pro",
      price_cents: 4999,
      currency: "USD",
      status: :active,
      allowed_regions: ["US", "CA", "GB"]
    },
    "GAD-20050" => %{
      sku: "GAD-20050",
      name: "Legacy Gadget v1",
      price_cents: 1999,
      currency: "USD",
      status: :discontinued,
      discontinued_at: ~D[2024-06-01],
      allowed_regions: ["US"]
    },
    "GBL-30010" => %{
      sku: "GBL-30010",
      name: "Global Gizmo",
      price_cents: 8900,
      currency: "USD",
      status: :active,
      allowed_regions: ["GB", "DE", "FR"]
    }
  }

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because discontinued products, region
  # restrictions, and unlisted SKUs are all common, predictable states
  # in an e-commerce catalogue. Every time a customer adds an item to their
  # cart, these conditions may arise — they are not exceptional events,
  # and clients should be able to handle them without rescue blocks.
  def fetch(sku) when not is_binary(sku) or sku == "" do
    raise InvalidSkuError,
      message: "SKU must be a non-empty string, got: #{inspect(sku)}",
      sku: sku
  end

  def fetch(sku) do
    unless Regex.match?(@sku_regex, sku) do
      raise InvalidSkuError,
        message: "SKU '#{sku}' does not match the expected format (e.g. WDG-10001)",
        sku: sku
    end

    product = Map.get(@catalogue, sku)

    if is_nil(product) do
      raise ProductNotFoundError,
        message: "Product with SKU '#{sku}' does not exist in the catalogue",
        sku: sku
    end

    if product.status == :discontinued do
      raise DiscontinuedProductError,
        message: "Product '#{sku}' (#{product.name}) was discontinued on #{product.discontinued_at}",
        sku: sku,
        discontinued_at: product.discontinued_at
    end

    product
  end

  def fetch(sku, region) do
    product = fetch(sku)

    unless region in product.allowed_regions do
      raise RegionRestrictedError,
        message:
          "Product '#{sku}' is not available in region '#{region}'. " <>
            "Allowed: #{Enum.join(product.allowed_regions, ", ")}",
        sku: sku,
        region: region,
        allowed_regions: product.allowed_regions
    end

    product
  end
  # VALIDATION: SMELL END
end

defmodule CartManager do
  @moduledoc """
  Manages customer shopping cart state, including adding, removing,
  and updating line items.
  """

  require Logger

  def add_item(cart, sku, region) do
    Logger.debug("Adding SKU #{sku} to cart #{cart.id} for region #{region}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because adding an item to a cart is
    # a constant operation in which the product may be discontinued,
    # unavailable, or incorrectly referenced. These are not exceptional
    # events — but the client has no choice but to use try...rescue because
    # ProductCatalogue offers no tuple-based fetch variant.
    try do
      product = ProductCatalogue.fetch(sku, region)

      updated_items =
        case Enum.find_index(cart.items, &(&1.sku == sku)) do
          nil ->
            [%{sku: sku, name: product.name, price_cents: product.price_cents, quantity: 1} | cart.items]

          idx ->
            List.update_at(cart.items, idx, &%{&1 | quantity: &1.quantity + 1})
        end

      Logger.info("Added #{sku} to cart #{cart.id}")
      {:ok, %{cart | items: updated_items, updated_at: DateTime.utc_now()}}
    rescue
      e in ProductCatalogue.ProductNotFoundError ->
        Logger.warning("SKU #{e.sku} not found; cannot add to cart #{cart.id}")
        {:error, :product_not_found}

      e in ProductCatalogue.DiscontinuedProductError ->
        Logger.info("SKU #{e.sku} discontinued on #{e.discontinued_at}")
        {:error, :product_discontinued}

      e in ProductCatalogue.RegionRestrictedError ->
        Logger.info("SKU #{e.sku} not available in #{e.region}")
        {:error, {:region_restricted, e.allowed_regions}}

      e in ProductCatalogue.InvalidSkuError ->
        Logger.warning("Invalid SKU '#{e.sku}' provided to cart #{cart.id}")
        {:error, :invalid_sku}
    end
    # VALIDATION: SMELL END
  end
end
```
