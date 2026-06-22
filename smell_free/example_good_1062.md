**File:** `example_good_1062.md`

```elixir
defmodule Commerce.Order do
  @moduledoc """
  Event-sourced order aggregate. State is rebuilt entirely from a list of
  domain events. Commands are validated against current state and produce
  either new events or descriptive error tuples.
  """

  alias Commerce.Order.Events.{
    OrderPlaced,
    ItemAdded,
    ItemRemoved,
    OrderConfirmed,
    OrderCancelled
  }

  @type status :: :draft | :confirmed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          items: [map()],
          status: status(),
          total_cents: non_neg_integer(),
          version: non_neg_integer()
        }

  @enforce_keys [:id, :customer_id]
  defstruct id: nil,
            customer_id: nil,
            items: [],
            status: :draft,
            total_cents: 0,
            version: 0

  @spec place(String.t(), String.t()) :: {:ok, [OrderPlaced.t()]} | {:error, term()}
  def place(order_id, customer_id)
      when is_binary(order_id) and is_binary(customer_id) do
    event = %OrderPlaced{
      order_id: order_id,
      customer_id: customer_id,
      placed_at: DateTime.utc_now()
    }

    {:ok, [event]}
  end

  @spec add_item(t(), map()) :: {:ok, [ItemAdded.t()]} | {:error, term()}
  def add_item(%__MODULE__{status: :draft} = order, %{sku: sku, quantity: qty, unit_price_cents: price} = item)
      when is_binary(sku) and is_integer(qty) and qty > 0 and is_integer(price) and price > 0 do
    already_present = Enum.any?(order.items, &(&1.sku == sku))

    if already_present do
      {:error, {:item_already_in_order, sku}}
    else
      event = %ItemAdded{order_id: order.id, sku: sku, quantity: qty, unit_price_cents: price}
      {:ok, [event]}
    end
  end

  def add_item(%__MODULE__{status: status}, _item), do: {:error, {:invalid_status, status}}

  @spec confirm(t()) :: {:ok, [OrderConfirmed.t()]} | {:error, term()}
  def confirm(%__MODULE__{status: :draft, items: [_ | _]} = order) do
    event = %OrderConfirmed{order_id: order.id, confirmed_at: DateTime.utc_now()}
    {:ok, [event]}
  end

  def confirm(%__MODULE__{items: []}), do: {:error, :order_has_no_items}
  def confirm(%__MODULE__{status: status}), do: {:error, {:invalid_status, status}}

  @spec cancel(t(), String.t()) :: {:ok, [OrderCancelled.t()]} | {:error, term()}
  def cancel(%__MODULE__{status: status}, _reason) when status in [:cancelled] do
    {:error, {:invalid_status, status}}
  end

  def cancel(%__MODULE__{} = order, reason) when is_binary(reason) do
    event = %OrderCancelled{order_id: order.id, reason: reason, cancelled_at: DateTime.utc_now()}
    {:ok, [event]}
  end

  @spec rebuild([struct()]) :: t()
  def rebuild(events) when is_list(events) do
    Enum.reduce(events, %__MODULE__{id: nil, customer_id: nil}, &apply_event/2)
  end

  defp apply_event(%OrderPlaced{} = e, state) do
    %{state | id: e.order_id, customer_id: e.customer_id, status: :draft, version: state.version + 1}
  end

  defp apply_event(%ItemAdded{} = e, state) do
    item = %{sku: e.sku, quantity: e.quantity, unit_price_cents: e.unit_price_cents}
    new_total = state.total_cents + e.quantity * e.unit_price_cents
    %{state | items: [item | state.items], total_cents: new_total, version: state.version + 1}
  end

  defp apply_event(%ItemRemoved{sku: sku}, state) do
    {removed, remaining} = Enum.split_with(state.items, &(&1.sku == sku))
    deduct = removed |> Enum.map(&(&1.quantity * &1.unit_price_cents)) |> Enum.sum()
    %{state | items: remaining, total_cents: state.total_cents - deduct, version: state.version + 1}
  end

  defp apply_event(%OrderConfirmed{}, state) do
    %{state | status: :confirmed, version: state.version + 1}
  end

  defp apply_event(%OrderCancelled{}, state) do
    %{state | status: :cancelled, version: state.version + 1}
  end
end
```
