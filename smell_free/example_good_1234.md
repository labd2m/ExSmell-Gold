```elixir
defmodule Ecommerce.Orders.Fulfillment do
  @moduledoc """
  Manages the fulfillment lifecycle for placed orders.
  Each transition is explicitly validated and recorded with a timestamp.
  """

  alias Ecommerce.Orders.{Order, FulfillmentEvent}

  @type transition_result :: {:ok, Order.t()} | {:error, atom() | String.t()}

  @doc """
  Marks an order as confirmed by the warehouse.
  Requires the order to be in `:pending` status.
  """
  @spec confirm(Order.t()) :: transition_result()
  def confirm(%Order{status: :pending} = order) do
    apply_transition(order, :confirmed)
  end

  def confirm(%Order{status: status}) do
    {:error, {:invalid_transition, :pending, status}}
  end

  @doc """
  Marks an order as shipped with a tracking reference.
  Requires the order to be in `:confirmed` status.
  """
  @spec ship(Order.t(), String.t()) :: transition_result()
  def ship(%Order{status: :confirmed} = order, tracking_ref)
      when is_binary(tracking_ref) and tracking_ref != "" do
    apply_transition(order, :shipped, %{tracking_ref: tracking_ref})
  end

  def ship(%Order{status: :confirmed}, _tracking_ref) do
    {:error, "tracking_ref must be a non-empty string"}
  end

  def ship(%Order{status: status}, _tracking_ref) do
    {:error, {:invalid_transition, :confirmed, status}}
  end

  @doc """
  Marks an order as delivered.
  Requires the order to be in `:shipped` status.
  """
  @spec deliver(Order.t()) :: transition_result()
  def deliver(%Order{status: :shipped} = order) do
    apply_transition(order, :delivered)
  end

  def deliver(%Order{status: status}) do
    {:error, {:invalid_transition, :shipped, status}}
  end

  @doc """
  Cancels an order. Only pending or confirmed orders may be cancelled.
  """
  @spec cancel(Order.t(), String.t()) :: transition_result()
  def cancel(%Order{status: status} = order, reason)
      when status in [:pending, :confirmed] and is_binary(reason) and reason != "" do
    apply_transition(order, :cancelled, %{cancellation_reason: reason})
  end

  def cancel(%Order{status: status}, _reason) when status in [:shipped, :delivered, :cancelled] do
    {:error, {:invalid_transition, :pending_or_confirmed, status}}
  end

  def cancel(%Order{}, _reason) do
    {:error, "cancellation reason must be a non-empty string"}
  end

  @doc """
  Returns all fulfillment events recorded on the order.
  """
  @spec event_history(Order.t()) :: [FulfillmentEvent.t()]
  def event_history(%Order{fulfillment_events: events}) when is_list(events), do: events
  def event_history(%Order{}), do: []

  defp apply_transition(order, new_status, metadata \\ %{}) do
    event = FulfillmentEvent.new(order.status, new_status, metadata)
    updated_events = event_history(order) ++ [event]

    updated_order = %{
      order
      | status: new_status,
        fulfillment_events: updated_events,
        updated_at: DateTime.utc_now()
    }

    {:ok, updated_order}
  end
end

defmodule Ecommerce.Orders.FulfillmentEvent do
  @moduledoc """
  An immutable record of a single fulfillment status transition.
  """

  @type t :: %__MODULE__{
          from_status: atom(),
          to_status: atom(),
          metadata: map(),
          occurred_at: DateTime.t()
        }

  defstruct [:from_status, :to_status, :metadata, :occurred_at]

  @spec new(atom(), atom(), map()) :: t()
  def new(from_status, to_status, metadata \\ %{}) do
    %__MODULE__{
      from_status: from_status,
      to_status: to_status,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }
  end
end
```
