```elixir
defmodule Workflow.StateMachine do
  @moduledoc """
  Generic finite state machine engine for domain workflow transitions.
  Validates guard conditions, executes side-effect callbacks, and records
  each transition in an append-only history log.
  """

  @type state_name :: atom()
  @type event_name :: atom()
  @type context :: map()
  @type guard_fn :: (context() -> boolean())
  @type callback_fn :: (context() -> {:ok, context()} | {:error, String.t()})

  @type transition :: %{
    from: state_name(),
    event: event_name(),
    to: state_name(),
    guard: guard_fn() | nil,
    on_transition: callback_fn() | nil
  }

  @type history_entry :: %{
    from: state_name(),
    to: state_name(),
    event: event_name(),
    transitioned_at: DateTime.t()
  }

  @type machine :: %{
    current_state: state_name(),
    context: context(),
    transitions: [transition()],
    history: [history_entry()]
  }

  @spec new(state_name(), context(), [transition()]) :: {:ok, machine()} | {:error, String.t()}
  def new(initial_state, context, transitions)
      when is_atom(initial_state) and is_map(context) and is_list(transitions) do
    with :ok <- validate_transitions(transitions) do
      {:ok, %{current_state: initial_state, context: context, transitions: transitions, history: []}}
    end
  end

  @spec trigger(machine(), event_name()) :: {:ok, machine()} | {:error, String.t()}
  def trigger(%{current_state: state, context: ctx, transitions: transitions} = machine, event)
      when is_atom(event) do
    case find_transition(transitions, state, event, ctx) do
      {:ok, transition} -> apply_transition(machine, transition)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec can_trigger?(machine(), event_name()) :: boolean()
  def can_trigger?(%{current_state: state, context: ctx, transitions: transitions}, event) do
    match?({:ok, _}, find_transition(transitions, state, event, ctx))
  end

  @spec available_events(machine()) :: [event_name()]
  def available_events(%{current_state: state, context: ctx, transitions: transitions}) do
    transitions
    |> Enum.filter(&(&1.from == state and guard_passes?(&1.guard, ctx)))
    |> Enum.map(& &1.event)
    |> Enum.uniq()
  end

  @spec history(machine()) :: [history_entry()]
  def history(%{history: history}), do: history

  @spec find_transition([transition()], state_name(), event_name(), context()) ::
          {:ok, transition()} | {:error, String.t()}
  defp find_transition(transitions, from_state, event, ctx) do
    transitions
    |> Enum.filter(&(&1.from == from_state and &1.event == event))
    |> Enum.find(&guard_passes?(&1.guard, ctx))
    |> case do
      nil -> {:error, "No valid transition from :#{from_state} on event :#{event}"}
      transition -> {:ok, transition}
    end
  end

  @spec apply_transition(machine(), transition()) :: {:ok, machine()} | {:error, String.t()}
  defp apply_transition(machine, %{from: from, to: to, event: event, on_transition: callback}) do
    with {:ok, new_context} <- run_callback(callback, machine.context) do
      entry = %{from: from, to: to, event: event, transitioned_at: DateTime.utc_now()}
      updated = %{machine |
        current_state: to,
        context: new_context,
        history: [entry | machine.history]
      }
      {:ok, updated}
    end
  end

  @spec run_callback(callback_fn() | nil, context()) :: {:ok, context()} | {:error, String.t()}
  defp run_callback(nil, ctx), do: {:ok, ctx}
  defp run_callback(callback, ctx) when is_function(callback, 1), do: callback.(ctx)

  @spec guard_passes?(guard_fn() | nil, context()) :: boolean()
  defp guard_passes?(nil, _ctx), do: true
  defp guard_passes?(guard, ctx) when is_function(guard, 1), do: guard.(ctx)

  @spec validate_transitions([transition()]) :: :ok | {:error, String.t()}
  defp validate_transitions(transitions) do
    invalid = Enum.find(transitions, &invalid_transition?/1)

    if invalid do
      {:error, "Invalid transition definition: #{inspect(invalid)}"}
    else
      :ok
    end
  end

  @spec invalid_transition?(map()) :: boolean()
  defp invalid_transition?(%{from: f, event: e, to: t})
       when is_atom(f) and is_atom(e) and is_atom(t),
       do: false

  defp invalid_transition?(_), do: true
end
```
