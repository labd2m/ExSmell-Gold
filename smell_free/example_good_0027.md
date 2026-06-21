```elixir
defmodule Commerce.OrderAggregate do
  @moduledoc """
  A per-order GenServer that manages the lifecycle of a shopping order.

  Each aggregate is identified by an `order_id` string and registered via
  `Commerce.OrderRegistry`. Supports item accumulation, order confirmation,
  and cancellation with proper state-transition guards.
  """

  use GenServer

  require Logger

  @type order_id :: String.t()
  @type status :: :pending | :confirmed | :cancelled
  @type line_item :: %{sku: String.t(), quantity: pos_integer(), unit_price_cents: non_neg_integer()}
  @type order :: %{
          id: order_id(),
          customer_id: pos_integer(),
          items: [line_item()],
          status: status(),
          confirmed_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    order_id = Keyword.fetch!(opts, :order_id)
    GenServer.start_link(__MODULE__, opts, name: via(order_id))
  end

  @doc """
  Adds a line item to a pending order. Returns `{:error, :order_not_pending}` if
  the order has already been confirmed or cancelled.
  """
  @spec add_item(order_id(), line_item()) :: :ok | {:error, :order_not_pending}
  def add_item(order_id, item) when is_binary(order_id) and is_map(item) do
    GenServer.call(via(order_id), {:add_item, item})
  end

  @doc """
  Confirms the order. Returns `{:error, :empty_order}` if no items have been added,
  or `{:error, :order_not_pending}` if the order is already confirmed or cancelled.
  """
  @spec confirm(order_id()) :: {:ok, order()} | {:error, :empty_order | :order_not_pending}
  def confirm(order_id) when is_binary(order_id) do
    GenServer.call(via(order_id), :confirm)
  end

  @doc "Cancels a non-confirmed order."
  @spec cancel(order_id()) :: :ok | {:error, :order_not_pending}
  def cancel(order_id) when is_binary(order_id) do
    GenServer.call(via(order_id), :cancel)
  end

  @doc "Returns the current state of the order."
  @spec fetch(order_id()) :: {:ok, order()} | {:error, :not_found}
  def fetch(order_id) when is_binary(order_id) do
    case Registry.lookup(Commerce.OrderRegistry, order_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get)}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(opts) do
    order = %{
      id: Keyword.fetch!(opts, :order_id),
      customer_id: Keyword.fetch!(opts, :customer_id),
      items: [],
      status: :pending,
      confirmed_at: nil
    }

    {:ok, order}
  end

  @impl GenServer
  def handle_call({:add_item, _item}, _from, %{status: status} = state)
      when status != :pending do
    {:reply, {:error, :order_not_pending}, state}
  end

  def handle_call({:add_item, item}, _from, %{items: items} = state) do
    {:reply, :ok, %{state | items: [item | items]}}
  end

  @impl GenServer
  def handle_call(:confirm, _from, %{status: status} = state) when status != :pending do
    {:reply, {:error, :order_not_pending}, state}
  end

  def handle_call(:confirm, _from, %{items: []} = state) do
    {:reply, {:error, :empty_order}, state}
  end

  def handle_call(:confirm, _from, state) do
    confirmed = %{state | status: :confirmed, confirmed_at: DateTime.utc_now()}
    {:reply, {:ok, confirmed}, confirmed}
  end

  @impl GenServer
  def handle_call(:cancel, _from, %{status: status} = state) when status != :pending do
    {:reply, {:error, :order_not_pending}, state}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, %{state | status: :cancelled}}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  defp via(order_id) do
    {:via, Registry, {Commerce.OrderRegistry, order_id}}
  end
end
```
