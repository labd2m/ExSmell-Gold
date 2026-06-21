```elixir
defmodule Commerce.CartAggregate do
  @moduledoc """
  Models a shopping cart as a supervised GenServer aggregate. The cart
  accumulates line items, enforces per-item quantity limits, and computes
  totals on demand. Each mutation emits a domain event stored in the event
  log so downstream projections can stay in sync. The cart expires
  automatically after a configurable idle timeout.
  """

  use GenServer

  require Logger

  @type item_id :: String.t()
  @type line_item :: %{item_id: item_id(), name: String.t(), unit_price_cents: pos_integer(), quantity: pos_integer()}
  @type state :: %{cart_id: String.t(), items: %{item_id() => line_item()}, events: [map()]}

  @max_item_quantity 99
  @idle_timeout_ms :timer.minutes(30)

  @doc "Starts a cart GenServer registered via a Registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    cart_id = Keyword.fetch!(opts, :cart_id)
    GenServer.start_link(__MODULE__, opts, name: via(cart_id))
  end

  @doc "Adds or increases the quantity of an item in the cart."
  @spec add_item(String.t(), line_item()) ::
          :ok | {:error, :quantity_limit_exceeded}
  def add_item(cart_id, %{item_id: _} = item) do
    GenServer.call(via(cart_id), {:add_item, item})
  end

  @doc "Removes an item from the cart entirely."
  @spec remove_item(String.t(), item_id()) :: :ok
  def remove_item(cart_id, item_id) when is_binary(item_id) do
    GenServer.cast(via(cart_id), {:remove_item, item_id})
  end

  @doc "Returns all line items currently in the cart."
  @spec items(String.t()) :: [line_item()]
  def items(cart_id), do: GenServer.call(via(cart_id), :items)

  @doc "Returns the subtotal in cents across all line items."
  @spec subtotal_cents(String.t()) :: non_neg_integer()
  def subtotal_cents(cart_id), do: GenServer.call(via(cart_id), :subtotal_cents)

  @impl GenServer
  def init(opts) do
    {:ok, %{cart_id: Keyword.fetch!(opts, :cart_id), items: %{}, events: []},
     @idle_timeout_ms}
  end

  @impl GenServer
  def handle_call({:add_item, %{item_id: id, quantity: qty} = item}, _from, state) do
    existing_qty = state.items |> Map.get(id, %{quantity: 0}) |> Map.get(:quantity, 0)
    new_qty = existing_qty + qty

    if new_qty > @max_item_quantity do
      {:reply, {:error, :quantity_limit_exceeded}, state, @idle_timeout_ms}
    else
      updated_item = Map.put(item, :quantity, new_qty)
      new_state = state |> put_in([:items, id], updated_item) |> append_event(:item_added, %{item_id: id, quantity: qty})
      {:reply, :ok, new_state, @idle_timeout_ms}
    end
  end

  def handle_call(:items, _from, state) do
    {:reply, Map.values(state.items), state, @idle_timeout_ms}
  end

  def handle_call(:subtotal_cents, _from, state) do
    total = Enum.sum_by(Map.values(state.items), fn i -> i.unit_price_cents * i.quantity end)
    {:reply, total, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_cast({:remove_item, item_id}, state) do
    new_state = state |> update_in([:items], &Map.delete(&1, item_id)) |> append_event(:item_removed, %{item_id: item_id})
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.info("[CartAggregate] Cart #{state.cart_id} expired due to inactivity")
    {:stop, :normal, state}
  end

  defp append_event(state, name, meta) do
    event = Map.merge(%{name: name, occurred_at: DateTime.utc_now()}, meta)
    update_in(state, [:events], &[event | &1])
  end

  defp via(cart_id), do: {:via, Registry, {Commerce.CartRegistry, cart_id}}
end
```
