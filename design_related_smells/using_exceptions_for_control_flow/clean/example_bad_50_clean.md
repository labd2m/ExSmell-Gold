```elixir
defmodule OrderStateMachine do
  @moduledoc """
  Enforces valid state transitions for the order lifecycle.

  Valid transitions:
    pending     -> confirmed | cancelled
    confirmed   -> processing | cancelled
    processing  -> shipped
    shipped     -> delivered
    delivered   -> (terminal)
    cancelled   -> (terminal)
  """

  defmodule InvalidTransitionError do
    defexception [:message, :from_state, :to_state, :order_id]

    @impl true
    def exception(opts) do
      from = Keyword.fetch!(opts, :from_state)
      to = Keyword.fetch!(opts, :to_state)
      order_id = Keyword.get(opts, :order_id)

      %__MODULE__{
        message:
          "Cannot transition order #{order_id || "(unknown)"} " <>
            "from #{from} to #{to}",
        from_state: from,
        to_state: to,
        order_id: order_id
      }
    end
  end

  @transitions %{
    pending: [:confirmed, :cancelled],
    confirmed: [:processing, :cancelled],
    processing: [:shipped],
    shipped: [:delivered],
    delivered: [],
    cancelled: []
  }

  @terminal_states [:delivered, :cancelled]

  def valid_transitions(state), do: Map.get(@transitions, state, [])
  def terminal?(state), do: state in @terminal_states

  def transition!(order, to_state) do
    from_state = order.status

    unless Map.has_key?(@transitions, from_state) do
      raise InvalidTransitionError,
        from_state: from_state,
        to_state: to_state,
        order_id: order.id
    end

    if terminal?(from_state) do
      raise InvalidTransitionError,
        from_state: from_state,
        to_state: to_state,
        order_id: order.id
    end

    allowed = Map.fetch!(@transitions, from_state)

    unless to_state in allowed do
      raise InvalidTransitionError,
        from_state: from_state,
        to_state: to_state,
        order_id: order.id
    end

    %{order | status: to_state, updated_at: DateTime.utc_now()}
  end

  def history_entry(from_state, to_state, actor_id) do
    %{
      from: from_state,
      to: to_state,
      actor_id: actor_id,
      occurred_at: DateTime.utc_now()
    }
  end
end

defmodule OrderProcessor do
  @moduledoc """
  Applies order lifecycle transitions, records history, and triggers
  downstream side-effects such as notifications and fulfillment actions.
  """

  require Logger

  alias OrderStateMachine
  alias OrderStateMachine.InvalidTransitionError

  def advance_order(order, to_state, actor_id) do
    Logger.info(
      "Attempting to advance order #{order.id} from #{order.status} to #{to_state} " <>
        "(actor: #{actor_id})"
    )

    # Forced to use try/rescue because OrderStateMachine.transition!/2 raises
    # exceptions for expected invalid-transition scenarios.
    try do
      updated_order = OrderStateMachine.transition!(order, to_state)
      history = OrderStateMachine.history_entry(order.status, to_state, actor_id)

      full_order = Map.update(updated_order, :history, [history], &[history | &1])

      side_effect = run_side_effects(to_state, full_order)

      Logger.info(
        "Order #{order.id} advanced to #{to_state} successfully (side-effect: #{side_effect})"
      )

      {:ok, full_order}
    rescue
      e in InvalidTransitionError ->
        Logger.warning(
          "Invalid order transition rejected for #{order.id}: #{e.message}"
        )

        {:error, {:invalid_transition, e.message}}
    end
  end

  def batch_advance(orders, to_state, actor_id) do
    Enum.map(orders, fn order ->
      case advance_order(order, to_state, actor_id) do
        {:ok, updated} ->
          {:ok, updated.id}

        {:error, reason} ->
          {:error, order.id, reason}
      end
    end)
  end

  defp run_side_effects(:confirmed, order) do
    Logger.info("Sending order confirmation email for order #{order.id}")
    :confirmation_sent
  end

  defp run_side_effects(:shipped, order) do
    Logger.info("Triggering shipment notification for order #{order.id}")
    :notification_sent
  end

  defp run_side_effects(:delivered, order) do
    Logger.info("Scheduling delivery feedback survey for order #{order.id}")
    :survey_scheduled
  end

  defp run_side_effects(:cancelled, order) do
    Logger.info("Initiating refund process for cancelled order #{order.id}")
    :refund_initiated
  end

  defp run_side_effects(_, _order), do: :no_op
end
```
