# Annotated Bad Example 21: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Ecommerce.Cart.build_item_label/1`
- **Affected function(s)**: `build_item_label/1`
- **Short explanation**: The function uses string interpolation (which internally calls `to_string/1` via the `String.Chars` protocol) on `item.quantity`, `item.name`, and `item.variant` without guard clauses. While `:name` is expected to be a binary, `:variant` is often passed as a map (e.g., `%{color: "red", size: "M"}`) from upstream parsers, which does not implement `String.Chars`. This will raise `Protocol.UndefinedError` at runtime. The function should guard or pattern-match each field to make the accepted domain explicit.

## Code

```elixir
defmodule Ecommerce.Cart do
  @moduledoc """
  Manages shopping cart state and item formatting for the e-commerce platform.
  Handles item addition, removal, quantity updates, and price summarization.
  """

  @max_quantity 999
  @free_shipping_threshold_cents 15_000

  @doc """
  Adds an item to the cart. If the item already exists (matched by SKU),
  its quantity is incremented.
  """
  def add_item(cart, item) when is_map(cart) and is_map(item) do
    sku = Map.fetch!(item, :sku)
    qty = Map.get(item, :quantity, 1)

    updated_items =
      case Enum.find_index(cart.items, &(&1.sku == sku)) do
        nil ->
          [item | cart.items]

        idx ->
          List.update_at(cart.items, idx, fn existing ->
            new_qty = min(existing.quantity + qty, @max_quantity)
            Map.put(existing, :quantity, new_qty)
          end)
      end

    %{cart | items: updated_items}
  end

  @doc """
  Removes an item from the cart by SKU.
  """
  def remove_item(cart, sku) when is_map(cart) and is_binary(sku) do
    updated = Enum.reject(cart.items, &(&1.sku == sku))
    %{cart | items: updated}
  end

  @doc """
  Returns the cart subtotal in cents.
  """
  def subtotal(cart) when is_map(cart) do
    Enum.reduce(cart.items, 0, fn item, acc ->
      acc + item.unit_price_cents * item.quantity
    end)
  end

  @doc """
  Returns whether this cart qualifies for free shipping.
  """
  def free_shipping?(cart) when is_map(cart) do
    subtotal(cart) >= @free_shipping_threshold_cents
  end

  @doc """
  Builds a human-readable label for a cart line item.
  Used in order confirmation emails and checkout summaries.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because Elixir string interpolation (`#{}`) calls
  # `to_string/1` via the `String.Chars` protocol on each interpolated value.
  # There is no guard clause or pattern match on the `item` struct fields.
  # If `item.variant` is a `Map` (e.g., `%{color: "red", size: "M"}`), which is
  # common when variants are stored as embedded JSON, the interpolation will raise
  # `Protocol.UndefinedError` at runtime. Passing `item.quantity` as a string
  # instead of an integer will silently produce a valid-looking label. The function
  # should destructure and validate each field explicitly.
  def build_item_label(item) do
    "#{item.quantity}x #{item.name} (#{item.variant})"
  end
  # VALIDATION: SMELL END

  @doc """
  Returns a list of all item labels for the given cart.
  """
  def item_labels(cart) when is_map(cart) do
    Enum.map(cart.items, &build_item_label/1)
  end

  @doc """
  Applies a percentage discount to the cart subtotal.
  Returns `{:ok, discounted_total}` or `{:error, :invalid_discount}`.
  """
  def apply_discount(cart, percent)
      when is_map(cart) and is_number(percent) and percent >= 0 and percent <= 100 do
    base = subtotal(cart)
    discount = trunc(base * percent / 100)
    {:ok, base - discount}
  end

  def apply_discount(_, _), do: {:error, :invalid_discount}

  @doc """
  Returns the total item count across all line items.
  """
  def total_item_count(cart) when is_map(cart) do
    Enum.sum(Enum.map(cart.items, & &1.quantity))
  end

  @doc """
  Returns true if the cart has no items.
  """
  def empty?(cart) when is_map(cart), do: cart.items == []

  @doc """
  Converts a cart map to a serializable format for session storage.
  """
  def to_session_payload(cart) when is_map(cart) do
    %{
      items: Enum.map(cart.items, fn item ->
        Map.take(item, [:sku, :name, :quantity, :unit_price_cents, :variant])
      end),
      coupon_code: Map.get(cart, :coupon_code)
    }
  end
end
```
