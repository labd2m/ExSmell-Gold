# File: `example_good_12.md`

```elixir
defmodule Orders.Aggregate do
  @moduledoc """
  Pure functional aggregate representing the lifecycle of an order.

  State is derived entirely from a sequence of domain events; no
  database calls occur here. The module exposes command functions
  that produce events and apply functions that fold events into state.
  """

  alias Orders.Aggregate.{LineItem, State}

  @type order_id :: String.t()
  @type product_id :: String.t()

  @type event ::
          {:order_placed, %{order_id: order_id(), customer_id: String.t(), placed_at: DateTime.t()}}
          | {:line_item_added, %{product_id: product_id(), quantity: pos_integer(), unit_price_cents: pos_integer()}}
          | {:line_item_removed, %{product_id: product_id()}}
          | {:order_confirmed, %{confirmed_at: DateTime.t()}}
          | {:order_cancelled, %{reason: String.t(), cancelled_at: DateTime.t()}}

  @doc """
  Initialises a new, empty order state.
  """
  @spec new() :: State.t()
  def new do
    %State{status: :draft, items: %{}, total_cents: 0}
  end

  @doc """
  Reconstitutes an order from a list of historical events.
  """
  @spec from_events([event()]) :: State.t()
  def from_events(events) when is_list(events) do
    Enum.reduce(events, new(), &apply_event(&2, &1))
  end

  @doc """
  Emits the event required to place an order.

  Returns `{:ok, [event]}` or `{:error, reason}`.
  """
  @spec place(State.t(), String.t(), String.t()) ::
          {:ok, [event()]} | {:error, :already_placed}
  def place(%State{status: :draft}, order_id, customer_id)
      when is_binary(order_id) and is_binary(customer_id) do
    event = {:order_placed, %{order_id: order_id, customer_id: customer_id, placed_at: DateTime.utc_now()}}
    {:ok, [event]}
  end

  def place(%State{}, _order_id, _customer_id), do: {:error, :already_placed}

  @doc """
  Emits the event required to add a line item to a draft order.

  Returns `{:ok, [event]}` or `{:error, reason}`.
  """
  @spec add_item(State.t(), product_id(), pos_integer(), pos_integer()) ::
          {:ok, [event()]} | {:error, :order_not_draft | :invalid_quantity}
  def add_item(%State{status: :draft}, product_id, quantity, unit_price_cents)
      when is_binary(product_id) and is_integer(quantity) and quantity > 0 and
             is_integer(unit_price_cents) and unit_price_cents > 0 do
    event =
      {:line_item_added,
       %{product_id: product_id, quantity: quantity, unit_price_cents: unit_price_cents}}

    {:ok, [event]}
  end

  def add_item(%State{status: :draft}, _product_id, _qty, _price) do
    {:error, :invalid_quantity}
  end

  def add_item(%State{}, _product_id, _qty, _price), do: {:error, :order_not_draft}

  @doc """
  Emits the event required to remove a line item from a draft order.
  """
  @spec remove_item(State.t(), product_id()) ::
          {:ok, [event()]} | {:error, :order_not_draft | :item_not_found}
  def remove_item(%State{status: :draft, items: items}, product_id) when is_binary(product_id) do
    if Map.has_key?(items, product_id) do
      {:ok, [{:line_item_removed, %{product_id: product_id}}]}
    else
      {:error, :item_not_found}
    end
  end

  def remove_item(%State{}, _product_id), do: {:error, :order_not_draft}

  @doc """
  Emits the event required to confirm a placed order.
  """
  @spec confirm(State.t()) :: {:ok, [event()]} | {:error, :not_placed | :no_items}
  def confirm(%State{status: :placed, items: items}) when map_size(items) > 0 do
    {:ok, [{:order_confirmed, %{confirmed_at: DateTime.utc_now()}}]}
  end

  def confirm(%State{status: :placed}), do: {:error, :no_items}
  def confirm(%State{}), do: {:error, :not_placed}

  @doc false
  @spec apply_event(State.t(), event()) :: State.t()
  def apply_event(state, {:order_placed, %{order_id: id, customer_id: cid}}) do
    %State{state | order_id: id, customer_id: cid, status: :placed}
  end

  def apply_event(state, {:line_item_added, %{product_id: pid, quantity: qty, unit_price_cents: price}}) do
    item = %LineItem{product_id: pid, quantity: qty, unit_price_cents: price}
    new_items = Map.put(state.items, pid, item)
    %State{state | items: new_items, total_cents: compute_total(new_items)}
  end

  def apply_event(state, {:line_item_removed, %{product_id: pid}}) do
    new_items = Map.delete(state.items, pid)
    %State{state | items: new_items, total_cents: compute_total(new_items)}
  end

  def apply_event(state, {:order_confirmed, _}), do: %State{state | status: :confirmed}

  def apply_event(state, {:order_cancelled, %{reason: reason}}) do
    %State{state | status: :cancelled, cancellation_reason: reason}
  end

  defp compute_total(items) do
    Enum.reduce(items, 0, fn {_pid, item}, acc ->
      acc + item.quantity * item.unit_price_cents
    end)
  end
end
```
