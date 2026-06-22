```elixir
defmodule EventStore.OrderAggregate.State do
  @moduledoc "Value object representing the current projected state of an Order aggregate."

  defstruct [:order_id, :customer_id, :items, :tracking_ref, status: :new]

  @type t :: %__MODULE__{
          order_id: String.t() | nil,
          customer_id: String.t() | nil,
          items: list() | nil,
          tracking_ref: String.t() | nil,
          status: :new | :placed | :confirmed | :shipped | :cancelled
        }

  @doc "Returns the initial empty state for a new aggregate instance."
  @spec initial() :: t()
  def initial, do: %__MODULE__{}
end

defmodule EventStore.OrderAggregate do
  @moduledoc """
  Event-sourced aggregate root for the Order domain.

  State is rebuilt by folding a chronological event stream through
  `apply_event/2`. Commands validate business invariants against current
  state and return either new domain events or typed errors. No I/O or
  side effects occur during command handling or event application.
  """

  alias EventStore.OrderAggregate.State
  alias EventStore.OrderAggregate.Events

  @type command ::
          {:place_order, map()}
          | {:confirm_order, String.t()}
          | {:ship_order, String.t()}
          | {:cancel_order, String.t()}

  @type command_result :: {:ok, [struct()]} | {:error, atom()}

  @doc "Rebuilds aggregate state by folding a list of historical events."
  @spec rebuild([struct()]) :: State.t()
  def rebuild(events) when is_list(events) do
    Enum.reduce(events, State.initial(), &apply_event(&2, &1))
  end

  @doc "Validates and handles a command against the current aggregate state."
  @spec handle(State.t(), command()) :: command_result()
  def handle(%State{status: :new}, {:place_order, params}) do
    with :ok <- validate_place_params(params) do
      {:ok, [%Events.OrderPlaced{
        order_id: params.order_id,
        customer_id: params.customer_id,
        items: params.items,
        placed_at: DateTime.utc_now()
      }]}
    end
  end

  def handle(%State{status: :placed}, {:confirm_order, order_id}) when is_binary(order_id) do
    {:ok, [%Events.OrderConfirmed{order_id: order_id, confirmed_at: DateTime.utc_now()}]}
  end

  def handle(%State{status: :confirmed}, {:ship_order, tracking_ref})
      when is_binary(tracking_ref) do
    {:ok, [%Events.OrderShipped{tracking_ref: tracking_ref, shipped_at: DateTime.utc_now()}]}
  end

  def handle(%State{status: status}, {:cancel_order, _reason})
      when status in [:placed, :confirmed] do
    {:ok, [%Events.OrderCancelled{cancelled_at: DateTime.utc_now()}]}
  end

  def handle(%State{status: :shipped}, {:cancel_order, _}),
    do: {:error, :order_already_shipped}

  def handle(_state, _command), do: {:error, :invalid_command_for_current_state}

  @doc "Evolves aggregate state by applying a single domain event."
  @spec apply_event(State.t(), struct()) :: State.t()
  def apply_event(%State{} = state, %Events.OrderPlaced{} = e) do
    %State{state | order_id: e.order_id, customer_id: e.customer_id,
                   items: e.items, status: :placed}
  end

  def apply_event(%State{} = state, %Events.OrderConfirmed{}) do
    %State{state | status: :confirmed}
  end

  def apply_event(%State{} = state, %Events.OrderShipped{} = e) do
    %State{state | status: :shipped, tracking_ref: e.tracking_ref}
  end

  def apply_event(%State{} = state, %Events.OrderCancelled{}) do
    %State{state | status: :cancelled}
  end

  def apply_event(state, _unknown_event), do: state

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp validate_place_params(%{order_id: id, customer_id: cid, items: items})
       when is_binary(id) and is_binary(cid) and is_list(items) and length(items) > 0,
       do: :ok

  defp validate_place_params(_), do: {:error, :invalid_order_params}
end
```
