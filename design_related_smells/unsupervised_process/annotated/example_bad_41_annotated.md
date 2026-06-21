# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `ApprovalWorkflow.start/1`
- **Affected function(s):** `ApprovalWorkflow.start/1`, `WorkflowEngine.submit/2`
- **Short explanation:** Each approval workflow (e.g. expense, leave, purchase order) runs as a standalone `GenServer` started via `GenServer.start/3`. Without a supervisor, a process crash silently terminates the approval chain; approvers can no longer act, and the submitter receives no notification.

```elixir
defmodule ApprovalWorkflow do
  use GenServer

  @moduledoc """
  Manages a multi-step approval workflow. Supports sequential and parallel
  approval chains with escalation timeouts and delegation.
  """

  @escalation_timeout_ms 48 * 60 * 60 * 1_000

  defstruct [
    :workflow_id,
    :entity_type,
    :entity_id,
    :submitted_by,
    :submitted_at,
    :current_step_index,
    :status,
    steps: [],
    history: []
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because approval workflows can span hours or days,
  # waiting for human reviewers to act. Each workflow process is created with
  # `GenServer.start/3` outside any supervision tree. If the process crashes
  # (e.g. due to an unexpected message or memory pressure), the entire approval
  # chain is silently lost — pending approvers are never notified, escalation
  # timers are gone, and the submitter's request disappears without explanation.
  def start(%{workflow_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end
  # VALIDATION: SMELL END

  def approve(workflow_id, approver_id, comment \\ nil) do
    GenServer.call(via(workflow_id), {:decision, :approved, approver_id, comment})
  end

  def reject(workflow_id, approver_id, reason) do
    GenServer.call(via(workflow_id), {:decision, :rejected, approver_id, reason})
  end

  def delegate(workflow_id, from_approver, to_approver) do
    GenServer.call(via(workflow_id), {:delegate, from_approver, to_approver})
  end

  def current_step(workflow_id) do
    GenServer.call(via(workflow_id), :current_step)
  end

  def full_state(workflow_id) do
    GenServer.call(via(workflow_id), :full_state)
  end

  defp via(id), do: {:via, Registry, {WorkflowRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{workflow_id: id, entity_type: etype, entity_id: eid, submitted_by: sub, steps: steps}) do
    state = %__MODULE__{
      workflow_id: id,
      entity_type: etype,
      entity_id: eid,
      submitted_by: sub,
      submitted_at: DateTime.utc_now(),
      current_step_index: 0,
      status: :pending,
      steps: steps
    }

    notify_approvers(hd(steps))
    schedule_escalation()
    {:ok, state}
  end

  @impl true
  def handle_call({:decision, decision, approver_id, comment}, _from, %{status: :pending} = state) do
    current_step = Enum.at(state.steps, state.current_step_index)

    if approver_id in current_step.approvers do
      event = %{step: state.current_step_index, approver: approver_id, decision: decision, comment: comment, at: DateTime.utc_now()}
      history = [event | state.history]

      case {decision, state.current_step_index + 1 >= length(state.steps)} do
        {:approved, true} ->
          emit_outcome(:approved, state)
          {:reply, {:ok, :workflow_approved}, %{state | status: :approved, history: history}}

        {:approved, false} ->
          next_index = state.current_step_index + 1
          next_step = Enum.at(state.steps, next_index)
          notify_approvers(next_step)
          {:reply, {:ok, :step_approved}, %{state | current_step_index: next_index, history: history}}

        {:rejected, _} ->
          emit_outcome(:rejected, state)
          {:reply, {:ok, :workflow_rejected}, %{state | status: :rejected, history: history}}
      end
    else
      {:reply, {:error, :not_an_approver}, state}
    end
  end

  def handle_call({:decision, _decision, _approver, _comment}, _from, state) do
    {:reply, {:error, {:workflow_not_pending, state.status}}, state}
  end

  def handle_call({:delegate, from_id, to_id}, _from, state) do
    current_step = Enum.at(state.steps, state.current_step_index)

    updated_approvers =
      current_step.approvers
      |> List.delete(from_id)
      |> then(&[to_id | &1])

    updated_step = %{current_step | approvers: updated_approvers}
    updated_steps = List.replace_at(state.steps, state.current_step_index, updated_step)
    {:reply, :ok, %{state | steps: updated_steps}}
  end

  def handle_call(:current_step, _from, state) do
    step = Enum.at(state.steps, state.current_step_index)
    {:reply, {:ok, step, state.current_step_index}, state}
  end

  def handle_call(:full_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:escalate, %{status: :pending} = state) do
    current_step = Enum.at(state.steps, state.current_step_index)
    IO.inspect({state.workflow_id, current_step}, label: "[ApprovalWorkflow] Escalating")
    schedule_escalation()
    {:noreply, state}
  end

  def handle_info(:escalate, state), do: {:noreply, state}

  defp notify_approvers(%{approvers: approvers} = step) do
    IO.inspect({approvers, step.label}, label: "[ApprovalWorkflow] Notifying approvers")
  end

  defp emit_outcome(outcome, state) do
    IO.inspect({state.workflow_id, outcome}, label: "[ApprovalWorkflow] Outcome")
  end

  defp schedule_escalation do
    Process.send_after(self(), :escalate, @escalation_timeout_ms)
  end
end

defmodule WorkflowEngine do
  @moduledoc "Submits entities for multi-step approval workflows."

  def submit(entity_id, opts) do
    workflow_id = "WF-#{entity_id}-#{System.unique_integer([:positive])}"

    attrs = %{
      workflow_id: workflow_id,
      entity_type: Keyword.fetch!(opts, :entity_type),
      entity_id: entity_id,
      submitted_by: Keyword.fetch!(opts, :submitted_by),
      steps: Keyword.fetch!(opts, :steps)
    }

    case ApprovalWorkflow.start(attrs) do
      {:ok, _pid} -> {:ok, workflow_id}
      {:error, reason} -> {:error, reason}
    end
  end
end
```
