```elixir
defmodule StateMachine.Transition do
  @moduledoc """
  Describes a single valid state transition including an optional guard function.
  """

  @type t :: %__MODULE__{
          event: atom(),
          from: atom() | [atom()],
          to: atom(),
          guard: (map() -> boolean()) | nil,
          action: (map() -> map()) | nil
        }

  defstruct [:event, :from, :to, :guard, :action]
end

defmodule StateMachine do
  alias StateMachine.Transition

  @moduledoc """
  A data-driven finite state machine engine. Define transitions declaratively
  and use `trigger/3` to advance state. Context is threaded through actions.
  """

  @type t :: %__MODULE__{
          current_state: atom(),
          context: map(),
          history: [{atom(), DateTime.t()}]
        }

  defstruct [:current_state, context: %{}, history: []]

  @spec new(atom(), map()) :: t()
  def new(initial_state, context \\ %{}) when is_atom(initial_state) and is_map(context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %__MODULE__{current_state: initial_state, context: context, history: [{initial_state, now}]}
  end

  @spec trigger(t(), atom(), [Transition.t()]) ::
          {:ok, t()} | {:error, :no_matching_transition | :guard_rejected}
  def trigger(%__MODULE__{} = machine, event, transitions)
      when is_atom(event) and is_list(transitions) do
    matching = find_transition(transitions, event, machine.current_state)

    case matching do
      nil ->
        {:error, :no_matching_transition}

      transition ->
        evaluate_transition(machine, transition)
    end
  end

  @spec can_trigger?(t(), atom(), [Transition.t()]) :: boolean()
  def can_trigger?(%__MODULE__{} = machine, event, transitions) do
    case find_transition(transitions, event, machine.current_state) do
      nil -> false
      transition -> guard_passes?(transition, machine.context)
    end
  end

  @spec available_events(t(), [Transition.t()]) :: [atom()]
  def available_events(%__MODULE__{} = machine, transitions) do
    transitions
    |> Enum.filter(fn t ->
      state_matches?(t.from, machine.current_state) and guard_passes?(t, machine.context)
    end)
    |> Enum.map(& &1.event)
    |> Enum.uniq()
  end

  defp find_transition(transitions, event, current_state) do
    Enum.find(transitions, fn t ->
      t.event == event and state_matches?(t.from, current_state)
    end)
  end

  defp state_matches?(from, current) when is_atom(from), do: from == current
  defp state_matches?(from, current) when is_list(from), do: current in from

  defp evaluate_transition(machine, transition) do
    if guard_passes?(transition, machine.context) do
      new_context = apply_action(transition, machine.context)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      updated = %{machine |
        current_state: transition.to,
        context: new_context,
        history: machine.history ++ [{transition.to, now}]
      }

      {:ok, updated}
    else
      {:error, :guard_rejected}
    end
  end

  defp guard_passes?(%Transition{guard: nil}, _context), do: true
  defp guard_passes?(%Transition{guard: guard}, context), do: guard.(context)

  defp apply_action(%Transition{action: nil}, context), do: context
  defp apply_action(%Transition{action: action}, context), do: action.(context)
end
```
