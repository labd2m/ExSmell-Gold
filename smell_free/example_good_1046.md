```elixir
defmodule Ecommerce.Cart.Aggregate do
  @moduledoc """
  Models a shopping cart as a pure domain aggregate. All mutations return
  a new cart struct; no side effects occur inside this module. Persistence
  and event emission are the caller's responsibility.
  """

  alias Ecommerce.Cart.{Cart, LineItem, PricingPolicy}

  @type add_item_result :: {:ok, Cart.t()} | {:error, :duplicate_item | :invalid_quantity}
  @type remove_item_result :: {:ok, Cart.t()} | {:error, :item_not_found}
  @type apply_coupon_result :: {:ok, Cart.t()} | {:error, :invalid_coupon | :already_applied}

  @doc "Creates a new empty cart for the given customer."
  @spec new(String.t()) :: Cart.t()
  def new(customer_id) when is_binary(customer_id) do
    %Cart{
      id: generate_id(),
      customer_id: customer_id,
      line_items: [],
      coupon: nil,
      created_at: DateTime.utc_now()
    }
  end

  @doc "Adds a line item to the cart. Rejects duplicates and invalid quantities."
  @spec add_item(Cart.t(), LineItem.t()) :: add_item_result()
  def add_item(%Cart{line_items: items} = cart, %LineItem{} = item) do
    cond do
      item.quantity <= 0 ->
        {:error, :invalid_quantity}

      Enum.any?(items, &(&1.sku == item.sku)) ->
        {:error, :duplicate_item}

      true ->
        {:ok, %{cart | line_items: [item | items]}}
    end
  end

  @doc "Removes a line item by SKU. Returns error if the SKU is not present."
  @spec remove_item(Cart.t(), String.t()) :: remove_item_result()
  def remove_item(%Cart{line_items: items} = cart, sku) when is_binary(sku) do
    case Enum.reject(items, &(&1.sku == sku)) do
      ^items -> {:error, :item_not_found}
      updated -> {:ok, %{cart | line_items: updated}}
    end
  end

  @doc "Applies a coupon to the cart if valid and not already applied."
  @spec apply_coupon(Cart.t(), String.t(), PricingPolicy.t()) :: apply_coupon_result()
  def apply_coupon(%Cart{coupon: existing}, _code, _policy) when not is_nil(existing) do
    {:error, :already_applied}
  end

  def apply_coupon(%Cart{} = cart, code, %PricingPolicy{} = policy) when is_binary(code) do
    case PricingPolicy.validate_coupon(policy, code) do
      {:ok, coupon} -> {:ok, %{cart | coupon: coupon}}
      {:error, :invalid_coupon} -> {:error, :invalid_coupon}
    end
  end

  @doc "Calculates the order total in cents, applying any coupon discount."
  @spec total(Cart.t()) :: non_neg_integer()
  def total(%Cart{line_items: items, coupon: coupon}) do
    subtotal = Enum.reduce(items, 0, &(&1.unit_price_cents * &1.quantity + &2))
    apply_discount(subtotal, coupon)
  end

  @doc "Returns `true` when the cart has at least one line item."
  @spec non_empty?(Cart.t()) :: boolean()
  def non_empty?(%Cart{line_items: items}), do: items != []

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec apply_discount(non_neg_integer(), map() | nil) :: non_neg_integer()
  defp apply_discount(subtotal, nil), do: subtotal

  defp apply_discount(subtotal, %{type: :percentage, value: pct}) do
    discount = round(subtotal * pct / 100)
    max(0, subtotal - discount)
  end

  defp apply_discount(subtotal, %{type: :fixed, value: amount}) do
    max(0, subtotal - amount)
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
