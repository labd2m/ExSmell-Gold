```elixir
defmodule Orders.LineItem do
  @moduledoc """
  An individual product line within an order.
  """

  @type t :: %__MODULE__{
          product_id: String.t(),
          product_name: String.t(),
          quantity: pos_integer(),
          unit_price_cents: non_neg_integer()
        }

  defstruct [:product_id, :product_name, :quantity, :unit_price_cents]

  @spec subtotal(%__MODULE__{}) :: non_neg_integer()
  def subtotal(%__MODULE__{quantity: qty, unit_price_cents: price}), do: qty * price
end

defmodule Orders.Order do
  @moduledoc """
  Aggregate root representing an order's lifecycle from draft through fulfilment.
  State transitions are enforced explicitly; invalid transitions return errors.
  """

  alias Orders.LineItem

  @type status :: :draft | :confirmed | :paid | :shipped | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          line_items: [LineItem.t()],
          status: status(),
          discount_cents: non_neg_integer(),
          placed_at: DateTime.t() | nil,
          paid_at: DateTime.t() | nil
        }

  defstruct [:id, :customer_id, :placed_at, :paid_at,
             line_items: [], status: :draft, discount_cents: 0]

  @spec new(String.t(), String.t()) :: t()
  def new(id, customer_id) when is_binary(id) and is_binary(customer_id) do
    %__MODULE__{id: id, customer_id: customer_id}
  end

  @spec add_line_item(t(), LineItem.t()) :: {:ok, t()} | {:error, :order_not_editable}
  def add_line_item(%__MODULE__{status: :draft} = order, %LineItem{} = item) do
    {:ok, %{order | line_items: order.line_items ++ [item]}}
  end

  def add_line_item(%__MODULE__{}, _item), do: {:error, :order_not_editable}

  @spec apply_discount(t(), non_neg_integer()) :: {:ok, t()} | {:error, :order_not_editable}
  def apply_discount(%__MODULE__{status: :draft} = order, cents)
      when is_integer(cents) and cents >= 0 do
    {:ok, %{order | discount_cents: cents}}
  end

  def apply_discount(%__MODULE__{}, _cents), do: {:error, :order_not_editable}

  @spec confirm(t()) :: {:ok, t()} | {:error, :empty_order | :invalid_transition}
  def confirm(%__MODULE__{status: :draft, line_items: []}), do: {:error, :empty_order}

  def confirm(%__MODULE__{status: :draft} = order) do
    {:ok, %{order | status: :confirmed, placed_at: DateTime.utc_now() |> DateTime.truncate(:second)}}
  end

  def confirm(%__MODULE__{}), do: {:error, :invalid_transition}

  @spec mark_paid(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_paid(%__MODULE__{status: :confirmed} = order) do
    {:ok, %{order | status: :paid, paid_at: DateTime.utc_now() |> DateTime.truncate(:second)}}
  end

  def mark_paid(%__MODULE__{}), do: {:error, :invalid_transition}

  @spec cancel(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def cancel(%__MODULE__{status: status} = order) when status in [:draft, :confirmed] do
    {:ok, %{order | status: :cancelled}}
  end

  def cancel(%__MODULE__{}), do: {:error, :invalid_transition}

  @spec total_cents(t()) :: non_neg_integer()
  def total_cents(%__MODULE__{line_items: items, discount_cents: discount}) do
    gross = Enum.reduce(items, 0, fn item, acc -> acc + LineItem.subtotal(item) end)
    max(gross - discount, 0)
  end
end
```
