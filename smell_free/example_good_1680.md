```elixir
defmodule Shop.CartAggregate do
  @moduledoc """
  An event-sourced shopping cart aggregate. State is rebuilt by replaying
  domain events; commands validate preconditions before emitting new events.
  No direct mutations to persisted state occur outside the event log.
  """

  @type cart_id :: String.t()
  @type item :: %{sku: String.t(), name: String.t(), unit_price_cents: pos_integer(), quantity: pos_integer()}

  @type state :: %{
          cart_id: cart_id(),
          items: %{String.t() => item()},
          status: :open | :checked_out | :abandoned,
          coupon_code: String.t() | nil
        }

  @type event ::
          {:item_added, %{sku: String.t(), name: String.t(), unit_price_cents: pos_integer(), quantity: pos_integer()}}
          | {:item_removed, %{sku: String.t()}}
          | {:quantity_updated, %{sku: String.t(), quantity: pos_integer()}}
          | {:coupon_applied, %{code: String.t()}}
          | {:coupon_removed, %{}}
          | {:cart_checked_out, %{}}
          | {:cart_abandoned, %{}}

  @type command_result :: {:ok, [event()]} | {:error, atom()}

  @spec initial_state(cart_id()) :: state()
  def initial_state(cart_id) do
    %{cart_id: cart_id, items: %{}, status: :open, coupon_code: nil}
  end

  @spec apply_event(state(), event()) :: state()
  def apply_event(state, {:item_added, attrs}) do
    existing_qty = get_in(state, [:items, attrs.sku, :quantity]) || 0
    updated_item = Map.put(attrs, :quantity, existing_qty + attrs.quantity)
    put_in(state, [:items, attrs.sku], updated_item)
  end

  def apply_event(state, {:item_removed, %{sku: sku}}) do
    update_in(state, [:items], &Map.delete(&1, sku))
  end

  def apply_event(state, {:quantity_updated, %{sku: sku, quantity: qty}}) do
    update_in(state, [:items, sku, :quantity], fn _ -> qty end)
  end

  def apply_event(state, {:coupon_applied, %{code: code}}) do
    %{state | coupon_code: code}
  end

  def apply_event(state, {:coupon_removed, _}) do
    %{state | coupon_code: nil}
  end

  def apply_event(state, {:cart_checked_out, _}) do
    %{state | status: :checked_out}
  end

  def apply_event(state, {:cart_abandoned, _}) do
    %{state | status: :abandoned}
  end

  @spec add_item(state(), map()) :: command_result()
  def add_item(%{status: :open}, %{sku: sku, name: name, unit_price_cents: price, quantity: qty})
      when is_binary(sku) and is_integer(qty) and qty > 0 and is_integer(price) and price > 0 do
    {:ok, [{:item_added, %{sku: sku, name: name, unit_price_cents: price, quantity: qty}}]}
  end

  def add_item(%{status: status}, _item) when status != :open, do: {:error, :cart_not_open}
  def add_item(_, _), do: {:error, :invalid_item}

  @spec remove_item(state(), String.t()) :: command_result()
  def remove_item(%{status: :open, items: items}, sku) when is_binary(sku) do
    if Map.has_key?(items, sku) do
      {:ok, [{:item_removed, %{sku: sku}}]}
    else
      {:error, :item_not_in_cart}
    end
  end

  def remove_item(_, _), do: {:error, :cart_not_open}

  @spec checkout(state()) :: command_result()
  def checkout(%{status: :open, items: items}) when map_size(items) > 0 do
    {:ok, [{:cart_checked_out, %{}}]}
  end

  def checkout(%{status: :open}), do: {:error, :cart_is_empty}
  def checkout(_), do: {:error, :cart_not_open}

  @spec total_cents(state()) :: non_neg_integer()
  def total_cents(%{items: items}) do
    Enum.sum(Enum.map(items, fn {_, item} -> item.unit_price_cents * item.quantity end))
  end

  @spec rebuild([event()], cart_id()) :: state()
  def rebuild(events, cart_id) do
    Enum.reduce(events, initial_state(cart_id), &apply_event(&2, &1))
  end
end
```
