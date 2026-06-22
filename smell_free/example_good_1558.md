```elixir
defmodule Commerce.Orders.Aggregate do
  @moduledoc """
  Domain aggregate for order lifecycle management.

  Encapsulates all state transitions for a commerce order from creation
  through fulfillment, enforcing valid state machine progressions.
  """

  alias Commerce.Orders.{LineItem, ShippingAddress}
  alias Commerce.Inventory.ReservationService

  @type status :: :draft | :confirmed | :paid | :shipped | :cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          customer_id: Ecto.UUID.t(),
          line_items: [LineItem.t()],
          shipping_address: ShippingAddress.t() | nil,
          status: status(),
          total: Decimal.t()
        }

  defstruct [:id, :customer_id, :shipping_address, line_items: [], status: :draft, total: Decimal.new("0")]

  @doc """
  Creates a new draft order for the given customer.
  """
  @spec new(Ecto.UUID.t()) :: t()
  def new(customer_id) do
    %__MODULE__{
      id: Ecto.UUID.generate(),
      customer_id: customer_id
    }
  end

  @doc """
  Adds a line item to a draft order.

  Returns `{:error, :order_not_editable}` for non-draft orders.
  """
  @spec add_item(t(), LineItem.t()) :: {:ok, t()} | {:error, :order_not_editable}
  def add_item(%__MODULE__{status: :draft} = order, %LineItem{} = item) do
    updated_items = [item | order.line_items]
    updated_total = recalculate_total(updated_items)
    {:ok, %{order | line_items: updated_items, total: updated_total}}
  end

  def add_item(%__MODULE__{}, _item), do: {:error, :order_not_editable}

  @doc """
  Attaches a shipping address to a draft order.
  """
  @spec set_shipping_address(t(), ShippingAddress.t()) ::
          {:ok, t()} | {:error, :order_not_editable}
  def set_shipping_address(%__MODULE__{status: :draft} = order, %ShippingAddress{} = address) do
    {:ok, %{order | shipping_address: address}}
  end

  def set_shipping_address(%__MODULE__{}, _address), do: {:error, :order_not_editable}

  @doc """
  Transitions the order from `:draft` to `:confirmed` after inventory reservation.
  """
  @spec confirm(t()) ::
          {:ok, t()}
          | {:error, :missing_shipping_address}
          | {:error, :empty_order}
          | {:error, :reservation_failed}
  def confirm(%__MODULE__{line_items: []}), do: {:error, :empty_order}
  def confirm(%__MODULE__{shipping_address: nil}), do: {:error, :missing_shipping_address}

  def confirm(%__MODULE__{status: :draft} = order) do
    with :ok <- ReservationService.reserve(order.id, order.line_items) do
      {:ok, %{order | status: :confirmed}}
    end
  end

  def confirm(%__MODULE__{}), do: {:error, :order_not_editable}

  @doc """
  Marks the order as paid. Only valid for confirmed orders.
  """
  @spec mark_paid(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_paid(%__MODULE__{status: :confirmed} = order) do
    {:ok, %{order | status: :paid}}
  end

  def mark_paid(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Marks the order as shipped. Only valid for paid orders.
  """
  @spec mark_shipped(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_shipped(%__MODULE__{status: :paid} = order) do
    {:ok, %{order | status: :shipped}}
  end

  def mark_shipped(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Cancels a draft or confirmed order, releasing any inventory reservations.
  """
  @spec cancel(t()) :: {:ok, t()} | {:error, :cannot_cancel}
  def cancel(%__MODULE__{status: status} = order) when status in [:draft, :confirmed] do
    :ok = ReservationService.release(order.id)
    {:ok, %{order | status: :cancelled}}
  end

  def cancel(%__MODULE__{}), do: {:error, :cannot_cancel}

  defp recalculate_total(items) do
    Enum.reduce(items, Decimal.new("0"), fn item, acc ->
      line_total = Decimal.mult(item.unit_price, Decimal.new(item.quantity))
      Decimal.add(acc, line_total)
    end)
  end
end
```
