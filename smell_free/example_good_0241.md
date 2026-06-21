# File: `example_good_241.md`

```elixir
defmodule Workflow.ApprovalChain do
  @moduledoc """
  Pure functional aggregate representing a sequential multi-step approval
  workflow. Each step must be approved by an approver at the required level
  before the chain can advance to the next step.

  Commands produce events; events are folded into state. The aggregate
  holds no I/O concerns — callers persist events and call `from_events/1`
  to reconstitute state.
  """

  alias Workflow.ApprovalChain.{State, Step}

  @type approver_id :: String.t()
  @type step_index :: non_neg_integer()

  @type event ::
          {:chain_started, %{chain_id: String.t(), steps: [Step.t()], started_at: DateTime.t()}}
          | {:step_approved, %{step_index: step_index(), approver_id: approver_id(), approved_at: DateTime.t()}}
          | {:step_rejected, %{step_index: step_index(), approver_id: approver_id(), reason: String.t(), rejected_at: DateTime.t()}}
          | {:chain_completed, %{completed_at: DateTime.t()}}
          | {:chain_rejected, %{at_step: step_index(), rejected_at: DateTime.t()}}

  @doc """
  Initialises an empty chain state.
  """
  @spec new() :: State.t()
  def new, do: %State{status: :pending, current_step: 0, steps: [], events: []}

  @doc """
  Reconstitutes chain state from a list of previously persisted events.
  """
  @spec from_events([event()]) :: State.t()
  def from_events(events) when is_list(events) do
    Enum.reduce(events, new(), &apply_event(&2, &1))
  end

  @doc """
  Starts the approval chain with a list of step definitions.

  Returns `{:ok, [event]}` or `{:error, :already_started}`.
  """
  @spec start(State.t(), String.t(), [Step.t()]) ::
          {:ok, [event()]} | {:error, :already_started | :no_steps}
  def start(%State{status: :pending, steps: []}, _chain_id, []) do
    {:error, :no_steps}
  end

  def start(%State{status: :pending, steps: []}, chain_id, steps) when is_list(steps) do
    event = {:chain_started, %{chain_id: chain_id, steps: steps, started_at: DateTime.utc_now()}}
    {:ok, [event]}
  end

  def start(%State{}, _chain_id, _steps), do: {:error, :already_started}

  @doc """
  Approves the current pending step.

  Returns `{:ok, events}` which may include a `:chain_completed` event
  if this was the final step.
  """
  @spec approve(State.t(), approver_id()) ::
          {:ok, [event()]} | {:error, :not_active | :chain_not_started}
  def approve(%State{status: :active} = state, approver_id) when is_binary(approver_id) do
    approval = {:step_approved, %{
      step_index: state.current_step,
      approver_id: approver_id,
      approved_at: DateTime.utc_now()
    }}

    next_index = state.current_step + 1
    final_step = length(state.steps) - 1

    if next_index > final_step do
      completed = {:chain_completed, %{completed_at: DateTime.utc_now()}}
      {:ok, [approval, completed]}
    else
      {:ok, [approval]}
    end
  end

  def approve(%State{status: :pending}, _approver_id), do: {:error, :chain_not_started}
  def approve(%State{}, _approver_id), do: {:error, :not_active}

  @doc """
  Rejects the current pending step with a reason, terminating the chain.
  """
  @spec reject(State.t(), approver_id(), String.t()) ::
          {:ok, [event()]} | {:error, :not_active | :chain_not_started}
  def reject(%State{status: :active} = state, approver_id, reason)
      when is_binary(approver_id) and is_binary(reason) do
    rejection = {:step_rejected, %{
      step_index: state.current_step,
      approver_id: approver_id,
      reason: reason,
      rejected_at: DateTime.utc_now()
    }}

    chain_rejected = {:chain_rejected, %{at_step: state.current_step, rejected_at: DateTime.utc_now()}}
    {:ok, [rejection, chain_rejected]}
  end

  def reject(%State{status: :pending}, _approver_id, _reason), do: {:error, :chain_not_started}
  def reject(%State{}, _approver_id, _reason), do: {:error, :not_active}

  @doc false
  @spec apply_event(State.t(), event()) :: State.t()
  def apply_event(state, {:chain_started, %{steps: steps}}) do
    %State{state | status: :active, steps: steps, current_step: 0}
  end

  def apply_event(state, {:step_approved, %{step_index: idx}}) do
    %State{state | current_step: idx + 1}
  end

  def apply_event(state, {:step_rejected, _}), do: state

  def apply_event(state, {:chain_completed, _}) do
    %State{state | status: :completed}
  end

  def apply_event(state, {:chain_rejected, %{at_step: step}}) do
    %State{state | status: :rejected, current_step: step}
  end
end
```
