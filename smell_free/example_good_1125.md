```elixir
defmodule Commerce.Orders.Aggregate do
  @moduledoc """
  GenServer managing the lifecycle of a single commerce order aggregate.
  Applies domain commands and accumulates a list of resulting domain events.
  Each state transition is guarded by the current order status.
  """

  use GenServer

  alias Commerce.Orders.{Command, Event, LineItem}

  @type status :: :draft | :confirmed | :shipped | :delivered | :canceled
  @type state :: %{
          order_id: String.t(),
          customer_id: String.t(),
          status: status(),
          line_items: [LineItem.t()],
          events: [Event.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    order_id = Keyword.fetch!(opts, :order_id)
    GenServer.start_link(__MODULE__, opts, name: via(order_id))
  end

  @spec add_item(String.t(), LineItem.t()) :: :ok | {:error, String.t()}
  def add_item(order_id, %LineItem{} = item) when is_binary(order_id) do
    GenServer.call(via(order_id), {:add_item, item})
  end

  @spec confirm(String.t()) :: :ok | {:error, String.t()}
  def confirm(order_id) when is_binary(order_id) do
    GenServer.call(via(order_id), :confirm)
  end

  @spec ship(String.t(), String.t()) :: :ok | {:error, String.t()}
  def ship(order_id, tracking_number) when is_binary(order_id) and is_binary(tracking_number) do
    GenServer.call(via(order_id), {:ship, tracking_number})
  end

  @spec cancel(String.t(), String.t()) :: :ok | {:error, String.t()}
  def cancel(order_id, reason) when is_binary(order_id) and is_binary(reason) do
    GenServer.call(via(order_id), {:cancel, reason})
  end

  @spec drain_events(String.t()) :: [Event.t()]
  def drain_events(order_id) when is_binary(order_id) do
    GenServer.call(via(order_id), :drain_events)
  end

  @impl GenServer
  def init(opts) do
    initial_state = %{
      order_id: Keyword.fetch!(opts, :order_id),
      customer_id: Keyword.fetch!(opts, :customer_id),
      status: :draft,
      line_items: [],
      events: []
    }

    {:ok, initial_state}
  end

  @impl GenServer
  def handle_call({:add_item, item}, _from, %{status: :draft} = state) do
    event = Event.new(:item_added, %{item: item})
    updated = %{state | line_items: [item | state.line_items], events: [event | state.events]}
    {:reply, :ok, updated}
  end

  def handle_call({:add_item, _item}, _from, state) do
    {:reply, {:error, "cannot add items to a #{state.status} order"}, state}
  end

  @impl GenServer
  def handle_call(:confirm, _from, %{status: :draft, line_items: [_ | _]} = state) do
    event = Event.new(:order_confirmed, %{item_count: length(state.line_items)})
    {:reply, :ok, %{state | status: :confirmed, events: [event | state.events]}}
  end

  def handle_call(:confirm, _from, %{status: :draft} = state) do
    {:reply, {:error, "cannot confirm an order with no items"}, state}
  end

  def handle_call(:confirm, _from, state) do
    {:reply, {:error, "cannot confirm a #{state.status} order"}, state}
  end

  @impl GenServer
  def handle_call({:ship, tracking}, _from, %{status: :confirmed} = state) do
    event = Event.new(:order_shipped, %{tracking_number: tracking})
    {:reply, :ok, %{state | status: :shipped, events: [event | state.events]}}
  end

  def handle_call({:ship, _tracking}, _from, state) do
    {:reply, {:error, "cannot ship a #{state.status} order"}, state}
  end

  @impl GenServer
  def handle_call({:cancel, reason}, _from, %{status: status} = state)
      when status in [:draft, :confirmed] do
    event = Event.new(:order_canceled, %{reason: reason})
    {:reply, :ok, %{state | status: :canceled, events: [event | state.events]}}
  end

  def handle_call({:cancel, _reason}, _from, state) do
    {:reply, {:error, "cannot cancel a #{state.status} order"}, state}
  end

  @impl GenServer
  def handle_call(:drain_events, _from, state) do
    {:reply, Enum.reverse(state.events), %{state | events: []}}
  end

  defp via(order_id) do
    {:via, Registry, {Commerce.Orders.Registry, order_id}}
  end
end

defmodule Commerce.Orders.LineItem do
  @moduledoc "Value object representing a single product line in an order."

  @type t :: %__MODULE__{
          sku: String.t(),
          name: String.t(),
          quantity: pos_integer(),
          unit_price_cents: pos_integer()
        }

  @enforce_keys [:sku, :name, :quantity, :unit_price_cents]
  defstruct [:sku, :name, :quantity, :unit_price_cents]

  @spec new(String.t(), String.t(), pos_integer(), pos_integer()) :: t()
  def new(sku, name, quantity, unit_price_cents)
      when is_binary(sku) and is_binary(name) and is_integer(quantity) and quantity > 0 and
             is_integer(unit_price_cents) and unit_price_cents > 0 do
    %__MODULE__{sku: sku, name: name, quantity: quantity, unit_price_cents: unit_price_cents}
  end

  @spec total_cents(t()) :: pos_integer()
  def total_cents(%__MODULE__{quantity: q, unit_price_cents: p}), do: q * p
end
```
