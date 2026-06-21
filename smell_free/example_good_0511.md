```elixir
defmodule MyApp.Streaming.EventProjector do
  @moduledoc """
  Projects a stream of domain events onto a read-model state by applying
  typed event handlers in sequence. The projector is purely functional:
  given the same sequence of events it always produces the same state,
  making it safe to rebuild read models by replaying stored events.

  New event types are supported by adding a `project/2` function clause
  without modifying the projection loop.
  """

  alias MyApp.Streaming.{OrderProjection, Events}

  @type event :: Events.t()
  @type state :: OrderProjection.t()

  @doc """
  Folds `events` onto `initial_state`, returning the final projected state.
  Unknown event types are silently skipped; the state is unchanged.
  """
  @spec project_all(state(), [event()]) :: state()
  def project_all(initial_state, events) when is_list(events) do
    Enum.reduce(events, initial_state, &project/2)
  end

  @doc """
  Applies a single `event` to `state`, returning the updated projection.
  Returns `state` unchanged for unrecognised event types.
  """
  @spec project(event(), state()) :: state()
  def project(%Events.OrderPlaced{} = e, state) do
    %OrderProjection{
      state
      | order_id: e.order_id,
        customer_id: e.customer_id,
        status: :pending,
        total_cents: e.total_cents,
        placed_at: e.occurred_at
    }
  end

  def project(%Events.PaymentConfirmed{} = e, state) do
    %OrderProjection{
      state
      | status: :paid,
        paid_at: e.occurred_at,
        transaction_id: e.transaction_id
    }
  end

  def project(%Events.ShipmentDispatched{} = e, state) do
    %OrderProjection{
      state
      | status: :shipped,
        tracking_number: e.tracking_number,
        carrier: e.carrier,
        shipped_at: e.occurred_at
    }
  end

  def project(_unknown_event, state), do: state
end

defmodule MyApp.Streaming.OrderProjection do
  @moduledoc "Read-model projection of an order lifecycle."

  defstruct [
    :order_id,
    :customer_id,
    :status,
    :total_cents,
    :placed_at,
    :paid_at,
    :transaction_id,
    :tracking_number,
    :carrier,
    :shipped_at
  ]

  @type t :: %__MODULE__{
          order_id: String.t() | nil,
          customer_id: String.t() | nil,
          status: atom() | nil,
          total_cents: non_neg_integer() | nil,
          placed_at: DateTime.t() | nil,
          paid_at: DateTime.t() | nil,
          transaction_id: String.t() | nil,
          tracking_number: String.t() | nil,
          carrier: String.t() | nil,
          shipped_at: DateTime.t() | nil
        }

  @doc "Returns an empty initial projection state."
  @spec initial() :: t()
  def initial, do: %__MODULE__{}

  @doc "Returns `true` when all order lifecycle fields have been populated."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{} = p) do
    not is_nil(p.order_id) and
      not is_nil(p.paid_at) and
      not is_nil(p.shipped_at)
  end
end
```
