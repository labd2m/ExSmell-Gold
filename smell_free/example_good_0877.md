```elixir
defmodule MyApp.Commerce.CartSerializer do
  @moduledoc """
  Serialises and deserialises shopping cart state to and from a compact
  JSON representation suitable for storing in a signed cookie or a
  Redis session. The serialised form omits product details (which are
  fetched fresh on deserialisation) and retains only the stable keys
  needed to reconstruct the cart: item IDs, SKUs, quantities, and any
  applied coupon codes.
  """

  alias MyApp.Commerce.{Cart, CartItem}
  alias MyApp.Catalog

  @version 2
  @max_cookie_bytes 3_000

  @type serialised :: String.t()

  @doc """
  Converts `cart` to a compact JSON string. Returns
  `{:error, :cart_too_large}` when the serialised form exceeds the safe
  cookie size limit.
  """
  @spec serialise(Cart.t()) :: {:ok, serialised()} | {:error, :cart_too_large}
  def serialise(%Cart{} = cart) do
    payload = %{
      v: @version,
      sid: cart.session_id,
      items: Enum.map(cart.items, &serialise_item/1),
      coupons: cart.applied_coupon_codes
    }

    encoded = Jason.encode!(payload)

    if byte_size(encoded) <= @max_cookie_bytes do
      {:ok, encoded}
    else
      {:error, :cart_too_large}
    end
  end

  @doc """
  Reconstructs a `Cart` struct from a serialised string, hydrating
  product details from the catalog. Returns `{:error, :invalid}` for
  malformed input and silently drops items whose SKUs no longer exist.
  """
  @spec deserialise(serialised()) :: {:ok, Cart.t()} | {:error, :invalid}
  def deserialise(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, %{"v" => @version} = payload} ->
        reconstruct(payload)

      {:ok, %{"v" => old_version}} ->
        migrate_and_reconstruct(old_version, encoded)

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  @spec reconstruct(map()) :: {:ok, Cart.t()}
  defp reconstruct(payload) do
    raw_items = Map.get(payload, "items", [])
    skus = Enum.map(raw_items, & &1["sku"])
    products = Catalog.fetch_many_by_sku(skus)

    items =
      raw_items
      |> Enum.flat_map(fn raw ->
        case Map.get(products, raw["sku"]) do
          nil -> []
          product ->
            [%CartItem{
              id: raw["id"],
              sku: raw["sku"],
              product_id: product.id,
              quantity: raw["qty"],
              unit_price_cents: product.price_cents
            }]
        end
      end)

    cart = %Cart{
      session_id: Map.get(payload, "sid"),
      items: items,
      applied_coupon_codes: Map.get(payload, "coupons", [])
    }

    {:ok, cart}
  end

  @spec migrate_and_reconstruct(pos_integer(), serialised()) :: {:ok, Cart.t()} | {:error, :invalid}
  defp migrate_and_reconstruct(1, encoded) do
    case Jason.decode(encoded) do
      {:ok, v1_payload} ->
        migrated = migrate_v1_to_v2(v1_payload)
        reconstruct(migrated)

      _ ->
        {:error, :invalid}
    end
  end

  defp migrate_and_reconstruct(_version, _encoded), do: {:error, :invalid}

  @spec migrate_v1_to_v2(map()) :: map()
  defp migrate_v1_to_v2(payload) do
    payload
    |> Map.put("v", @version)
    |> Map.put("coupons", [])
  end

  @spec serialise_item(CartItem.t()) :: map()
  defp serialise_item(item) do
    %{id: item.id, sku: item.sku, qty: item.quantity}
  end
end
```
