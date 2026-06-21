```elixir
defmodule Commerce.Order do
  @moduledoc """
  An event-sourced aggregate representing a customer order. State is never
  mutated directly; instead, commands produce domain events that are applied
  to derive the current state. This makes the order lifecycle fully auditable
  and replayable from any point in history.
  """

  alias Commerce.Order.Events.{ItemAdded, OrderPlaced, OrderCancelled}

  @type status :: :draft | :placed | :cancelled | :fulfilled
  @type item :: %{sku_id: binary(), quantity: pos_integer(), unit_cents: pos_integer()}

  @type t :: %__MODULE__{
          id: binary(),
          customer_id: binary(),
          status: status(),
          items: [item()],
          total_cents: non_neg_integer(),
          version: non_neg_integer()
        }

  defstruct id: nil, customer_id: nil, status: :draft, items: [], total_cents: 0, version: 0

  # ---------------------------------------------------------------------------
  # Commands → Events
  # ---------------------------------------------------------------------------

  @doc """
  Adds a line item to a draft order. Returns the event to be persisted,
  or `{:error, reason}` if the order is not in a state that allows additions.
  """
  @spec add_item(t(), item()) :: {:ok, ItemAdded.t()} | {:error, :order_not_draft}
  def add_item(%__MODULE__{status: :draft}, item) do
    event = %ItemAdded{
      sku_id: item.sku_id,
      quantity: item.quantity,
      unit_cents: item.unit_cents,
      line_total_cents: item.quantity * item.unit_cents
    }

    {:ok, event}
  end

  def add_item(%__MODULE__{status: _status}, _item), do: {:error, :order_not_draft}

  @doc """
  Transitions a draft order to the `:placed` status. Requires at least
  one item to be present. Returns the event or an error tuple.
  """
  @spec place(t()) :: {:ok, OrderPlaced.t()} | {:error, :already_placed | :empty_order}
  def place(%__MODULE__{status: :placed}), do: {:error, :already_placed}
  def place(%__MODULE__{items: []}), do: {:error, :empty_order}

  def place(%__MODULE__{} = order) do
    {:ok, %OrderPlaced{order_id: order.id, total_cents: order.total_cents}}
  end

  @doc """
  Cancels a placed order. Fulfilled orders cannot be cancelled.
  """
  @spec cancel(t(), binary()) ::
          {:ok, OrderCancelled.t()} | {:error, :not_cancellable}
  def cancel(%__MODULE__{status: status}, reason)
      when status in [:draft, :placed] and is_binary(reason) do
    {:ok, %OrderCancelled{reason: reason}}
  end

  def cancel(%__MODULE__{}, _reason), do: {:error, :not_cancellable}

  # ---------------------------------------------------------------------------
  # Event application (state reconstruction)
  # ---------------------------------------------------------------------------

  @doc """
  Applies a persisted domain event to produce the next aggregate state.
  Used by the event store when rebuilding an aggregate from its history.
  """
  @spec apply_event(t(), struct()) :: t()
  def apply_event(order, %ItemAdded{} = event) do
    updated_items = [build_item(event) | order.items]

    %__MODULE__{
      order
      | items: updated_items,
        total_cents: order.total_cents + event.line_total_cents,
        version: order.version + 1
    }
  end

  def apply_event(order, %OrderPlaced{}) do
    %__MODULE__{order | status: :placed, version: order.version + 1}
  end

  def apply_event(order, %OrderCancelled{}) do
    %__MODULE__{order | status: :cancelled, version: order.version + 1}
  end

  @doc """
  Reconstitutes an order aggregate from an ordered list of domain events.
  """
  @spec load(t(), [struct()]) :: t()
  def load(%__MODULE__{} = initial, events) when is_list(events) do
    Enum.reduce(events, initial, &apply_event(&2, &1))
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_item(%ItemAdded{sku_id: sku_id, quantity: qty, unit_cents: unit}) do
    %{sku_id: sku_id, quantity: qty, unit_cents: unit}
  end
end

defmodule Commerce.Order.Events.ItemAdded do
  @moduledoc false
  defstruct [:sku_id, :quantity, :unit_cents, :line_total_cents]
  @type t :: %__MODULE__{sku_id: binary(), quantity: pos_integer(), unit_cents: pos_integer(), line_total_cents: pos_integer()}
end

defmodule Commerce.Order.Events.OrderPlaced do
  @moduledoc false
  defstruct [:order_id, :total_cents]
  @type t :: %__MODULE__{order_id: binary(), total_cents: non_neg_integer()}
end

defmodule Commerce.Order.Events.OrderCancelled do
  @moduledoc false
  defstruct [:reason]
  @type t :: %__MODULE__{reason: binary()}
end
```
