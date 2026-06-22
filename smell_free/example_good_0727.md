```elixir
defmodule Platform.StateMachine do
  @moduledoc """
  A behaviour and runtime for implementing explicit finite state machines.

  Modules implementing this behaviour declare their states, transitions,
  and side-effect callbacks. The runtime validates every transition against
  the declared graph and calls `on_enter/2` and `on_exit/2` callbacks around
  each state change, ensuring no invalid transitions can occur at runtime.
  """

  @type state :: atom()
  @type event :: atom()
  @type context :: map()
  @type transition_result :: {:ok, state(), context()} | {:error, :invalid_transition | term()}

  @doc "Returns the list of all valid states for this machine."
  @callback states() :: [state()]

  @doc "Returns the initial state of the machine."
  @callback initial_state() :: state()

  @doc """
  Returns the transition map as `%{from_state => %{event => to_state}}`.
  """
  @callback transitions() :: %{optional(state()) => %{optional(event()) => state()}}

  @doc "Called when entering `new_state` with `context`. May update context."
  @callback on_enter(state(), context()) :: {:ok, context()} | {:error, term()}

  @doc "Called when exiting `current_state`. Return value is ignored."
  @callback on_exit(state(), context()) :: :ok

  @optional_callbacks on_enter: 2, on_exit: 2

  @doc """
  Applies `event` to `current_state` using `machine`'s transition map.
  Calls lifecycle callbacks and returns the new state and context.
  """
  @spec transition(module(), state(), event(), context()) :: transition_result()
  def transition(machine, current_state, event, context \\ %{}) do
    transitions = machine.transitions()

    case get_in(transitions, [current_state, event]) do
      nil ->
        {:error, :invalid_transition}

      next_state ->
        with :ok <- call_on_exit(machine, current_state, context),
             {:ok, new_context} <- call_on_enter(machine, next_state, context) do
          {:ok, next_state, new_context}
        end
    end
  end

  @doc "Returns all valid events from `current_state` for `machine`."
  @spec valid_events(module(), state()) :: [event()]
  def valid_events(machine, current_state) do
    machine.transitions()
    |> Map.get(current_state, %{})
    |> Map.keys()
  end

  @doc "Returns `true` if `event` is valid from `current_state`."
  @spec can_transition?(module(), state(), event()) :: boolean()
  def can_transition?(machine, current_state, event) do
    event in valid_events(machine, current_state)
  end

  defp call_on_exit(machine, state, context) do
    if function_exported?(machine, :on_exit, 2) do
      machine.on_exit(state, context)
      :ok
    else
      :ok
    end
  end

  defp call_on_enter(machine, state, context) do
    if function_exported?(machine, :on_enter, 2) do
      machine.on_enter(state, context)
    else
      {:ok, context}
    end
  end
end

defmodule Commerce.OrderStateMachine do
  @moduledoc "State machine for e-commerce order lifecycle."

  @behaviour Platform.StateMachine

  require Logger

  @impl Platform.StateMachine
  def states, do: [:pending, :confirmed, :processing, :shipped, :delivered, :cancelled, :refunded]

  @impl Platform.StateMachine
  def initial_state, do: :pending

  @impl Platform.StateMachine
  def transitions do
    %{
      pending: %{confirm: :confirmed, cancel: :cancelled},
      confirmed: %{begin_processing: :processing, cancel: :cancelled},
      processing: %{ship: :shipped, cancel: :cancelled},
      shipped: %{deliver: :delivered},
      delivered: %{refund: :refunded},
      cancelled: %{},
      refunded: %{}
    }
  end

  @impl Platform.StateMachine
  def on_enter(:confirmed, context) do
    Logger.info("[OrderSM] Order confirmed", order_id: context[:order_id])
    {:ok, Map.put(context, :confirmed_at, DateTime.utc_now())}
  end

  def on_enter(:shipped, context) do
    Logger.info("[OrderSM] Order shipped", order_id: context[:order_id])
    {:ok, Map.put(context, :shipped_at, DateTime.utc_now())}
  end

  def on_enter(_state, context), do: {:ok, context}

  @impl Platform.StateMachine
  def on_exit(state, context) do
    Logger.debug("[OrderSM] Exiting state", state: state, order_id: context[:order_id])
    :ok
  end
end
```
