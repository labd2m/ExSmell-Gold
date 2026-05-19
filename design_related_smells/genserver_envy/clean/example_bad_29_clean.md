```elixir
defmodule MyApp.ApprovalWorkflowAgent do
  @moduledoc """
  Manages document approval workflows with multi-stage review,
  approval routing, rejection handling, and audit trails.
  """

  use Agent

  alias MyApp.{Repo, Mailer, AuditLog, PolicyEngine}
  alias MyApp.Approvals.{Workflow, ApprovalStage, Decision}

  @approval_stages [:legal, :finance, :executive]

  def start_link(_opts) do
    workflows = Repo.all(Workflow) |> Enum.into(%{}, &{&1.document_id, &1})
    Agent.start_link(fn -> %{workflows: workflows} end, name: __MODULE__)
  end

  def get_workflow(document_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.workflows, document_id) end)
  end

  def list_pending_for_reviewer(reviewer_id) do
    Agent.get(__MODULE__, fn state ->
      state.workflows
      |> Map.values()
      |> Enum.filter(fn wf ->
        wf.status == :pending and wf.current_reviewer == reviewer_id
      end)
    end)
  end

  def submit_for_approval(document_id, submitter_id, document_meta) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.workflows, document_id) do
        {{:error, :workflow_exists}, state}
      else
        first_stage = hd(@approval_stages)
        reviewer = PolicyEngine.assign_reviewer(first_stage, document_meta)

        workflow = %Workflow{
          id: Ecto.UUID.generate(),
          document_id: document_id,
          submitter_id: submitter_id,
          document_meta: document_meta,
          current_stage: first_stage,
          current_reviewer: reviewer,
          stages_completed: [],
          decisions: [],
          status: :pending,
          submitted_at: DateTime.utc_now()
        }

        case Repo.insert(workflow) do
          {:ok, saved} ->
            Mailer.notify_reviewer(reviewer, document_id, first_stage)
            AuditLog.record(:approval_submitted, %{doc: document_id, by: submitter_id})
            new_state = put_in(state, [:workflows, document_id], saved)
            {{:ok, saved}, new_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
      end
    end)
  end

  def approve(document_id, reviewer_id, comments) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, workflow} <- Map.fetch(state.workflows, document_id),
           :pending <- workflow.status,
           true <- workflow.current_reviewer == reviewer_id do
        decision = %Decision{
          stage: workflow.current_stage,
          reviewer_id: reviewer_id,
          verdict: :approved,
          comments: comments,
          decided_at: DateTime.utc_now()
        }

        completed = [workflow.current_stage | workflow.stages_completed]
        remaining_stages = @approval_stages -- completed

        {next_stage, next_reviewer, new_status} =
          case remaining_stages do
            [] ->
              {nil, nil, :approved}

            [next | _] ->
              reviewer = PolicyEngine.assign_reviewer(next, workflow.document_meta)
              {next, reviewer, :pending}
          end

        updated_workflow = %{
          workflow
          | current_stage: next_stage,
            current_reviewer: next_reviewer,
            stages_completed: completed,
            decisions: [decision | workflow.decisions],
            status: new_status
        }

        Repo.update!(updated_workflow)
        AuditLog.record(:approval_approved, %{doc: document_id, stage: workflow.current_stage})

        if new_status == :approved do
          Mailer.notify_submitter_approved(workflow.submitter_id, document_id)
        else
          Mailer.notify_reviewer(next_reviewer, document_id, next_stage)
        end

        {{:ok, updated_workflow}, put_in(state, [:workflows, document_id], updated_workflow)}
      else
        :error -> {{:error, :workflow_not_found}, state}
        status when is_atom(status) -> {{:error, {:wrong_status, status}}, state}
        false -> {{:error, :not_assigned_reviewer}, state}
      end
    end)
  end

  def reject(document_id, reviewer_id, reason) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, workflow} <- Map.fetch(state.workflows, document_id),
           :pending <- workflow.status,
           true <- workflow.current_reviewer == reviewer_id do
        decision = %Decision{
          stage: workflow.current_stage,
          reviewer_id: reviewer_id,
          verdict: :rejected,
          comments: reason,
          decided_at: DateTime.utc_now()
        }

        updated_workflow = %{
          workflow
          | status: :rejected,
            decisions: [decision | workflow.decisions]
        }

        Repo.update!(updated_workflow)
        AuditLog.record(:approval_rejected, %{doc: document_id, reason: reason})
        Mailer.notify_submitter_rejected(workflow.submitter_id, document_id, reason)

        {{:ok, :rejected}, put_in(state, [:workflows, document_id], updated_workflow)}
      else
        :error -> {{:error, :not_found}, state}
        status when is_atom(status) -> {{:error, {:wrong_status, status}}, state}
        false -> {{:error, :not_assigned_reviewer}, state}
      end
    end)
  end

  def list_by_status(status) do
    Agent.get(__MODULE__, fn state ->
      state.workflows |> Map.values() |> Enum.filter(&(&1.status == status))
    end)
  end
end
```
