```elixir
defmodule Fsm do
  @moduledoc """
  A lightweight macro that generates a compile-time validated finite state
  machine. Declaring states, initial state, and transitions at compile time
  means invalid transition paths are caught by the compiler rather than at
  runtime. The generated module exposes `transition/2` and `valid_transition?/2`
  so callers interact with a typed surface without knowing the underlying map.

  ## Usage

      defmodule MyFsm do
        use Fsm,
          initial: :idle,
          states: [:idle, :running, :paused, :stopped],
          transitions: [
            idle: [running: :start],
            running: [paused: :pause, stopped: :stop],
            paused: [running: :resume, stopped: :stop]
          ]
      end
  """

  defmacro __using__(opts) do
    initial = Keyword.fetch!(opts, :initial)
    states = Keyword.fetch!(opts, :states)
    transitions = Keyword.fetch!(opts, :transitions)

    validate_fsm!(initial, states, transitions)

    transition_map = build_transition_map(transitions)

    quote do
      @initial_state unquote(initial)
      @valid_states unquote(states)
      @transitions unquote(Macro.escape(transition_map))

      @doc "Returns the initial state of the FSM."
      @spec initial_state() :: atom()
      def initial_state, do: @initial_state

      @doc "Returns all valid states."
      @spec states() :: [atom()]
      def states, do: @valid_states

      @doc """
      Attempts to transition from `current_state` to `next_state`.
      Returns `{:ok, next_state}` or `{:error, :invalid_transition}`.
      """
      @spec transition(atom(), atom()) :: {:ok, atom()} | {:error, :invalid_transition}
      def transition(current_state, next_state) do
        reachable = Map.get(@transitions, current_state, [])

        if next_state in reachable do
          {:ok, next_state}
        else
          {:error, :invalid_transition}
        end
      end

      @doc "Returns true when transitioning from `current` to `next` is valid."
      @spec valid_transition?(atom(), atom()) :: boolean()
      def valid_transition?(current_state, next_state) do
        next_state in Map.get(@transitions, current_state, [])
      end

      @doc "Returns the set of reachable states from `current_state`."
      @spec reachable_from(atom()) :: [atom()]
      def reachable_from(current_state) do
        Map.get(@transitions, current_state, [])
      end

      @doc "Returns all transitions as a map of `from_state => [to_state]`."
      @spec transition_map() :: %{atom() => [atom()]}
      def transition_map, do: @transitions
    end
  end

  defp validate_fsm!(initial, states, transitions) do
    unless initial in states do
      raise ArgumentError, "initial state #{inspect(initial)} must be listed in :states"
    end

    Enum.each(transitions, fn {from, targets} ->
      unless from in states do
        raise ArgumentError, "transition source #{inspect(from)} is not a declared state"
      end

      Enum.each(targets, fn {to, _event} ->
        unless to in states do
          raise ArgumentError, "transition target #{inspect(to)} is not a declared state"
        end
      end)
    end)
  end

  defp build_transition_map(transitions) do
    Map.new(transitions, fn {from, targets} ->
      to_states = Enum.map(targets, fn {to, _event} -> to end)
      {from, to_states}
    end)
  end
end

defmodule Commerce.OrderFsm do
  @moduledoc """
  Compile-time validated state machine for the order lifecycle.
  """

  use Fsm,
    initial: :draft,
    states: [:draft, :placed, :confirmed, :shipped, :delivered, :cancelled, :refunded],
    transitions: [
      draft: [placed: :place],
      placed: [confirmed: :confirm, cancelled: :cancel],
      confirmed: [shipped: :ship, cancelled: :cancel],
      shipped: [delivered: :deliver],
      delivered: [refunded: :refund],
      cancelled: []
    ]
end
```
