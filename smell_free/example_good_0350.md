```elixir
defmodule Commerce.CartAggregate do
  @moduledoc """
  An event-sourced shopping cart aggregate.

  State is never mutated directly. Instead, commands produce events, and
  events are applied to a state struct via pure `apply/2` functions.
  The aggregate can be fully reconstructed from its event history at
  any point in time.
  """

  alias Commerce.CartAggregate.{State, Events}

  @type command ::
          {:add_item, map()}
          | {:remove_item, String.t()}
          | {:update_quantity, String.t(), pos_integer()}
          | :clear_cart

  @type event :: struct()
  @type execute_result :: {:ok, [event()]} | {:error, term()}

  @doc """
  Reconstructs the current cart state by replaying a list of events.
  Pass an empty list to start with a blank cart.
  """
  @spec project([event()]) :: State.t()
  def project(events) when is_list(events) do
    Enum.reduce(events, %State{}, &apply_event(&2, &1))
  end

  @doc """
  Executes a command against the current state and returns the events
  to be appended to the event stream.
  """
  @spec execute(State.t(), command()) :: execute_result()
  def execute(%State{status: :checked_out}, _command) do
    {:error, :cart_checked_out}
  end

  def execute(_state, {:add_item, %{sku: sku, quantity: qty, price_cents: price}})
      when is_binary(sku) and is_integer(qty) and qty > 0 and is_integer(price) do
    {:ok, [%Events.ItemAdded{sku: sku, quantity: qty, price_cents: price, added_at: DateTime.utc_now()}]}
  end

  def execute(%State{items: items}, {:remove_item, sku}) when is_binary(sku) do
    if Map.has_key?(items, sku) do
      {:ok, [%Events.ItemRemoved{sku: sku, removed_at: DateTime.utc_now()}]}
    else
      {:error, {:item_not_in_cart, sku}}
    end
  end

  def execute(%State{items: items}, {:update_quantity, sku, new_qty})
      when is_binary(sku) and is_integer(new_qty) and new_qty > 0 do
    if Map.has_key?(items, sku) do
      {:ok, [%Events.QuantityUpdated{sku: sku, new_quantity: new_qty, updated_at: DateTime.utc_now()}]}
    else
      {:error, {:item_not_in_cart, sku}}
    end
  end

  def execute(%State{items: items}, :clear_cart) when map_size(items) > 0 do
    {:ok, [%Events.CartCleared{cleared_at: DateTime.utc_now()}]}
  end

  def execute(%State{items: items}, :clear_cart) when map_size(items) == 0 do
    {:ok, []}
  end

  def execute(_state, _command), do: {:error, :invalid_command}

  defp apply_event(state, %Events.ItemAdded{sku: sku, quantity: qty, price_cents: price}) do
    item = %{sku: sku, quantity: qty, price_cents: price}
    %{state | items: Map.put(state.items, sku, item)}
  end

  defp apply_event(state, %Events.ItemRemoved{sku: sku}) do
    %{state | items: Map.delete(state.items, sku)}
  end

  defp apply_event(state, %Events.QuantityUpdated{sku: sku, new_quantity: qty}) do
    %{state | items: update_in(state.items, [sku, :quantity], fn _ -> qty end)}
  end

  defp apply_event(state, %Events.CartCleared{}) do
    %{state | items: %{}}
  end
end

defmodule Commerce.CartAggregate.State do
  @moduledoc "Value object representing the current cart state."

  @type t :: %__MODULE__{
          items: %{String.t() => map()},
          status: :open | :checked_out
        }

  defstruct items: %{}, status: :open
end

defmodule Commerce.CartAggregate.Events do
  @moduledoc "Event structs for the cart aggregate."

  defmodule ItemAdded do
    defstruct [:sku, :quantity, :price_cents, :added_at]
  end

  defmodule ItemRemoved do
    defstruct [:sku, :removed_at]
  end

  defmodule QuantityUpdated do
    defstruct [:sku, :new_quantity, :updated_at]
  end

  defmodule CartCleared do
    defstruct [:cleared_at]
  end
end
```
