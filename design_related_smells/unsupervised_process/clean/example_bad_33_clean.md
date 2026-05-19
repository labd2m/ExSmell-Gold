```elixir
defmodule OrderProcess do
  use GenServer

  @moduledoc """
  Manages the full lifecycle of a single customer order, from placement
  through payment confirmation, fulfillment, and shipping.
  """

  @valid_transitions %{
    pending: [:confirmed, :cancelled],
    confirmed: [:paid, :cancelled],
    paid: [:fulfilling, :refunded],
    fulfilling: [:shipped, :failed],
    shipped: [:delivered],
    delivered: [],
    cancelled: [],
    refunded: [],
    failed: []
  }

  defstruct [
    :order_id,
    :customer_id,
    :items,
    :total,
    :status,
    :placed_at,
    :updated_at,
    history: []
  ]

  def start(%{order_id: id} = order_attrs) do
    GenServer.start(__MODULE__, order_attrs, name: via(id))
  end

  def transition(order_id, new_status) do
    GenServer.call(via(order_id), {:transition, new_status})
  end

  def add_note(order_id, note) do
    GenServer.cast(via(order_id), {:note, note})
  end

  def fetch(order_id) do
    GenServer.call(via(order_id), :fetch)
  end

  def history(order_id) do
    GenServer.call(via(order_id), :history)
  end

  defp via(id), do: {:via, Registry, {OrderRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{order_id: id, customer_id: cid, items: items, total: total}) do
    now = DateTime.utc_now()

    state = %__MODULE__{
      order_id: id,
      customer_id: cid,
      items: items,
      total: total,
      status: :pending,
      placed_at: now,
      updated_at: now
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:transition, new_status}, _from, state) do
    allowed = Map.get(@valid_transitions, state.status, [])

    if new_status in allowed do
      now = DateTime.utc_now()

      event = %{
        from: state.status,
        to: new_status,
        at: now
      }

      updated = %{state |
        status: new_status,
        updated_at: now,
        history: [event | state.history]
      }

      {:reply, {:ok, new_status}, updated}
    else
      {:reply, {:error, {:invalid_transition, state.status, new_status}}, state}
    end
  end

  def handle_call(:fetch, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:history, _from, state) do
    {:reply, Enum.reverse(state.history), state}
  end

  @impl true
  def handle_cast({:note, note}, state) do
    event = %{type: :note, content: note, at: DateTime.utc_now()}
    {:noreply, %{state | history: [event | state.history]}}
  end
end

defmodule OrderService do
  @moduledoc "High-level API for order placement and management."

  def place(%{customer_id: _, items: _, total: _} = attrs) do
    order_id = generate_order_id()
    attrs = Map.put(attrs, :order_id, order_id)

    case OrderProcess.start(attrs) do
      {:ok, _pid} -> {:ok, order_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def confirm(order_id) do
    OrderProcess.transition(order_id, :confirmed)
  end

  def cancel(order_id) do
    OrderProcess.transition(order_id, :cancelled)
  end

  def mark_paid(order_id) do
    OrderProcess.transition(order_id, :paid)
  end

  defp generate_order_id do
    "ORD-#{System.unique_integer([:positive, :monotonic])}"
  end
end
```
