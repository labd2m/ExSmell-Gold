# Annotated Example — Code Smell

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `OrderStateMachine.transition!/2`
- **Affected function(s):** `OrderStateMachine.transition!/2`, `OrderProcessor.advance_order/3`
- **Short explanation:** `OrderStateMachine.transition!/2` raises `InvalidTransitionError` when a requested state change is not permitted by the order lifecycle rules. Invalid transitions are entirely expected in a production order-management system (e.g., a retry on an already-shipped order, a race condition). Because no `transition/2` variant returning `{:ok, new_state} | {:error, reason}` is provided, `OrderProcessor.advance_order/3` must use `try/rescue` for what should be ordinary state-check branching.

---

## Code

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

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because transition!/2 raises InvalidTransitionError
  # VALIDATION: for a predictable, non-exceptional business outcome. In a real order
  # VALIDATION: system, attempted invalid transitions occur regularly (concurrent
  # VALIDATION: updates, retries, UI glitches). Because no transition/2 returning
  # VALIDATION: {:ok, new_state} | {:error, reason} is provided, every caller is
  # VALIDATION: forced to use try/rescue for ordinary conditional logic.
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
  # VALIDATION: SMELL END

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
