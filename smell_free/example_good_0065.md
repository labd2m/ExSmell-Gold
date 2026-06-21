```elixir
defmodule Commerce.Cart.Item do
  @moduledoc """
  A catalog item eligible for placement into a shopping cart.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          sku: String.t(),
          name: String.t(),
          unit_price_cents: non_neg_integer(),
          currency: String.t()
        }

  defstruct [:id, :sku, :name, :unit_price_cents, :currency]
end

defmodule Commerce.Cart.LineItem do
  @moduledoc false

  alias Commerce.Cart.Item

  @type t :: %__MODULE__{
          item_id: String.t(),
          sku: String.t(),
          name: String.t(),
          unit_price_cents: non_neg_integer(),
          currency: String.t(),
          quantity: pos_integer()
        }

  defstruct [:item_id, :sku, :name, :unit_price_cents, :currency, :quantity]

  @spec from_item(Item.t(), pos_integer()) :: t()
  def from_item(%Item{} = item, quantity) when is_integer(quantity) and quantity > 0 do
    %__MODULE__{
      item_id: item.id,
      sku: item.sku,
      name: item.name,
      unit_price_cents: item.unit_price_cents,
      currency: item.currency,
      quantity: quantity
    }
  end

  @spec subtotal_cents(t()) :: non_neg_integer()
  def subtotal_cents(%__MODULE__{unit_price_cents: price, quantity: qty}), do: price * qty
end

defmodule Commerce.Cart do
  @moduledoc """
  A pure domain aggregate representing a customer's shopping cart.

  The cart tracks a collection of line items in a single currency.
  All mutations produce a new `Cart` struct; no state is altered in place.
  Cross-currency items are rejected with a typed error rather than silently
  mixing incompatible amounts.
  """

  alias Commerce.Cart.{Item, LineItem}

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          currency: String.t(),
          line_items: [LineItem.t()]
        }

  defstruct [:id, :customer_id, :currency, line_items: []]

  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(id, customer_id, currency)
      when is_binary(id) and is_binary(customer_id) and is_binary(currency) do
    %__MODULE__{id: id, customer_id: customer_id, currency: String.upcase(currency)}
  end

  @spec add_item(t(), Item.t(), pos_integer()) ::
          {:ok, t()} | {:error, :currency_mismatch}
  def add_item(%__MODULE__{currency: c} = cart, %Item{currency: c} = item, qty)
      when is_integer(qty) and qty > 0 do
    updated_items = merge_or_append(cart.line_items, item, qty)
    {:ok, %{cart | line_items: updated_items}}
  end

  def add_item(%__MODULE__{}, %Item{}, _qty), do: {:error, :currency_mismatch}

  @spec remove_item(t(), String.t()) :: t()
  def remove_item(%__MODULE__{} = cart, item_id) when is_binary(item_id) do
    %{cart | line_items: Enum.reject(cart.line_items, &(&1.item_id == item_id))}
  end

  @spec set_quantity(t(), String.t(), pos_integer()) ::
          {:ok, t()} | {:error, :item_not_found}
  def set_quantity(%__MODULE__{} = cart, item_id, qty)
      when is_binary(item_id) and is_integer(qty) and qty > 0 do
    case Enum.find_index(cart.line_items, &(&1.item_id == item_id)) do
      nil ->
        {:error, :item_not_found}

      idx ->
        updated = List.update_at(cart.line_items, idx, &%{&1 | quantity: qty})
        {:ok, %{cart | line_items: updated}}
    end
  end

  @spec total_cents(t()) :: non_neg_integer()
  def total_cents(%__MODULE__{line_items: items}) do
    Enum.reduce(items, 0, fn line, acc -> acc + LineItem.subtotal_cents(line) end)
  end

  @spec item_count(t()) :: non_neg_integer()
  def item_count(%__MODULE__{line_items: items}) do
    Enum.sum(Enum.map(items, & &1.quantity))
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{line_items: []}), do: true
  def empty?(%__MODULE__{}), do: false

  defp merge_or_append(line_items, item, qty) do
    case Enum.find_index(line_items, &(&1.item_id == item.id)) do
      nil ->
        line_items ++ [LineItem.from_item(item, qty)]

      idx ->
        List.update_at(line_items, idx, &%{&1 | quantity: &1.quantity + qty})
    end
  end
end
```
