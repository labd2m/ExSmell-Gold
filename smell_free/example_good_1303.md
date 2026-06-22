**File:** `example_good_1303.md`

```elixir
defmodule FSM.Transition do
  @moduledoc "Represents a single valid state transition with an optional guard."

  @enforce_keys [:from, :event, :to]
  defstruct [:from, :event, :to, :guard, :on_enter]

  @type state :: atom()
  @type event :: atom()
  @type guard :: (map() -> boolean()) | nil
  @type callback :: (map() -> map()) | nil

  @type t :: %__MODULE__{
          from: state(),
          event: event(),
          to: state(),
          guard: guard(),
          on_enter: callback()
        }

  @spec new(state(), event(), state(), keyword()) :: t()
  def new(from, event, to, opts \\ []) do
    %__MODULE__{
      from: from,
      event: event,
      to: to,
      guard: Keyword.get(opts, :guard),
      on_enter: Keyword.get(opts, :on_enter)
    }
  end
end

defmodule FSM.Machine do
  @moduledoc "Immutable state machine definition built from a list of transitions."

  alias FSM.Transition

  @enforce_keys [:transitions, :initial_state]
  defstruct [:transitions, :initial_state]

  @type t :: %__MODULE__{
          transitions: [Transition.t()],
          initial_state: Transition.state()
        }

  @spec new(Transition.state(), [Transition.t()]) :: t()
  def new(initial_state, transitions) when is_atom(initial_state) and is_list(transitions) do
    %__MODULE__{initial_state: initial_state, transitions: transitions}
  end

  @spec initial_context(t()) :: map()
  def initial_context(%__MODULE__{initial_state: state}) do
    %{state: state}
  end
end

defmodule FSM.Runner do
  @moduledoc """
  Executes events against a state machine definition and a mutable context map.
  Returns the updated context with the new state, or an error if the transition
  is undefined or its guard rejects the current context.
  """

  alias FSM.{Machine, Transition}

  @type context :: %{state: atom()}
  @type transition_result :: {:ok, context()} | {:error, :no_transition} | {:error, :guard_rejected}

  @spec trigger(Machine.t(), context(), atom()) :: transition_result()
  def trigger(%Machine{} = machine, %{state: current_state} = context, event) do
    machine.transitions
    |> find_transition(current_state, event)
    |> apply_transition(context)
  end

  @spec valid_events(Machine.t(), context()) :: [atom()]
  def valid_events(%Machine{transitions: transitions}, %{state: current_state} = context) do
    transitions
    |> Enum.filter(fn t -> t.from == current_state and guard_passes?(t, context) end)
    |> Enum.map(& &1.event)
  end

  defp find_transition(transitions, from, event) do
    Enum.find(transitions, fn t -> t.from == from and t.event == event end)
  end

  defp apply_transition(nil, _context), do: {:error, :no_transition}

  defp apply_transition(%Transition{} = transition, context) do
    if guard_passes?(transition, context) do
      updated = run_on_enter(transition, %{context | state: transition.to})
      {:ok, updated}
    else
      {:error, :guard_rejected}
    end
  end

  defp guard_passes?(%Transition{guard: nil}, _context), do: true
  defp guard_passes?(%Transition{guard: guard}, context), do: guard.(context)

  defp run_on_enter(%Transition{on_enter: nil}, context), do: context
  defp run_on_enter(%Transition{on_enter: callback}, context), do: callback.(context)
end

defmodule FSM.Examples.OrderFSM do
  @moduledoc "Example state machine for a simple order lifecycle."

  alias FSM.{Machine, Runner, Transition}

  @spec definition() :: Machine.t()
  def definition do
    transitions = [
      Transition.new(:pending, :confirm, :confirmed),
      Transition.new(:confirmed, :ship, :shipped,
        guard: fn ctx -> Map.get(ctx, :tracking_number) != nil end),
      Transition.new(:shipped, :deliver, :delivered),
      Transition.new(:pending, :cancel, :cancelled),
      Transition.new(:confirmed, :cancel, :cancelled)
    ]

    Machine.new(:pending, transitions)
  end

  @spec process(map(), atom()) :: FSM.Runner.transition_result()
  def process(context, event) do
    Runner.trigger(definition(), context, event)
  end
end
```
