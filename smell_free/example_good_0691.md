```elixir
defmodule Commerce.CartMerger do
  @moduledoc """
  Merges a guest cart into an authenticated user's cart upon sign-in.
  The merge strategy is additive: quantities for matching SKUs are summed
  and capped at the per-item maximum. Items present only in the guest
  cart are transferred. Items already in the user cart at maximum quantity
  are silently skipped. The operation is pure and returns a new cart
  state map without mutating either input.
  """

  @type sku :: String.t()
  @type line_item :: %{sku: sku(), quantity: pos_integer(), unit_price_cents: pos_integer()}
  @type cart :: %{items: [line_item()]}
  @type merge_result :: %{cart: cart(), skipped_skus: [sku()]}

  @max_quantity_per_sku 99

  @doc """
  Merges `guest_cart` items into `user_cart`. Returns the merged cart and
  a list of SKUs that were skipped because the quantity cap was already reached.
  """
  @spec merge(cart(), cart()) :: merge_result()
  def merge(%{items: user_items}, %{items: guest_items}) do
    user_index = Map.new(user_items, fn item -> {item.sku, item} end)

    {merged_index, skipped} =
      Enum.reduce(guest_items, {user_index, []}, fn guest_item, {idx, skipped_acc} ->
        case Map.get(idx, guest_item.sku) do
          nil ->
            {Map.put(idx, guest_item.sku, guest_item), skipped_acc}

          existing ->
            combined = existing.quantity + guest_item.quantity

            if combined > @max_quantity_per_sku do
              if existing.quantity >= @max_quantity_per_sku do
                {idx, [guest_item.sku | skipped_acc]}
              else
                capped = %{existing | quantity: @max_quantity_per_sku}
                {Map.put(idx, guest_item.sku, capped), skipped_acc}
              end
            else
              merged = %{existing | quantity: combined}
              {Map.put(idx, guest_item.sku, merged), skipped_acc}
            end
        end
      end)

    merged_items =
      merged_index
      |> Map.values()
      |> Enum.sort_by(& &1.sku)

    %{cart: %{items: merged_items}, skipped_skus: Enum.uniq(skipped)}
  end

  @doc "Returns the subtotal in cents for all items in `cart`."
  @spec subtotal_cents(cart()) :: non_neg_integer()
  def subtotal_cents(%{items: items}) do
    Enum.sum_by(items, fn i -> i.unit_price_cents * i.quantity end)
  end

  @doc "Returns the total item count across all line items in `cart`."
  @spec total_quantity(cart()) :: non_neg_integer()
  def total_quantity(%{items: items}) do
    Enum.sum_by(items, & &1.quantity)
  end

  @doc "Returns true when both carts contain identical items and quantities."
  @spec equal?(cart(), cart()) :: boolean()
  def equal?(%{items: a}, %{items: b}) do
    sorted = fn items ->
      Enum.sort_by(items, & &1.sku) |> Enum.map(&Map.take(&1, [:sku, :quantity]))
    end

    sorted.(a) == sorted.(b)
  end
end
```
