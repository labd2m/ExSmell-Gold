```elixir
defmodule Approvals.WorkflowEngine do
  @moduledoc """
  Executes configurable multi-step approval chains for domain entities such
  as expense reports, purchase orders, and content publications. Each step
  declares who may approve it and whether it auto-advances on unanimous
  approval or requires a single approver. The engine tracks step state
  independently so any step can be rejected without invalidating earlier
  approvals. All state transitions persist atomically.
  """

  alias Approvals.{Approval, ApprovalStep, Repo, Workflow}
  alias Ecto.Multi

  import Ecto.Query

  require Logger

  @type workflow_id :: binary()
  @type step_id :: binary()
  @type approver_id :: binary()
  @type decision :: :approved | :rejected
  @type outcome :: :pending | :approved | :rejected | :cancelled

  @doc """
  Creates a new workflow instance from a `template_name` for the given entity.
  Inserts all configured steps in pending state. Returns `{:ok, workflow}`.
  """
  @spec start(binary(), binary(), map()) ::
          {:ok, Workflow.t()} | {:error, term()}
  def start(template_name, entity_id, context \\ %{})
      when is_binary(template_name) and is_binary(entity_id) do
    with {:ok, template} <- Approvals.Templates.fetch(template_name) do
      Multi.new()
      |> Multi.insert(:workflow, Workflow.changeset(%Workflow{}, %{
           template_name: template_name,
           entity_id: entity_id,
           status: :pending,
           context: context
         }))
      |> Multi.run(:steps, fn repo, %{workflow: wf} ->
        steps =
          template.steps
          |> Enum.with_index(1)
          |> Enum.map(fn {step_cfg, position} ->
            %{
              workflow_id: wf.id,
              position: position,
              name: step_cfg.name,
              required_role: step_cfg.required_role,
              mode: step_cfg.mode,
              status: :pending,
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }
          end)

        {count, _} = repo.insert_all(ApprovalStep, steps, returning: true)
        {:ok, count}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{workflow: workflow}} ->
          Logger.info("Approval workflow started",
            template: template_name,
            entity_id: entity_id,
            workflow_id: workflow.id
          )
          {:ok, workflow}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Records `approver_id`'s decision for the current active step in `workflow_id`.
  Auto-advances the workflow when all required approvals are gathered.
  Returns `{:ok, workflow}` or `{:error, reason}`.
  """
  @spec decide(workflow_id(), approver_id(), decision()) ::
          {:ok, Workflow.t()} | {:error, term()}
  def decide(workflow_id, approver_id, decision)
      when is_binary(workflow_id) and is_binary(approver_id) and decision in [:approved, :rejected] do
    with {:ok, workflow} <- fetch_active(workflow_id),
         {:ok, step} <- fetch_active_step(workflow_id),
         :ok <- assert_authorised(step, approver_id),
         :ok <- assert_not_voted(step, approver_id) do
      record_decision(workflow, step, approver_id, decision)
    end
  end

  @doc """
  Returns the full workflow with all steps preloaded.
  """
  @spec fetch(workflow_id()) :: {:ok, Workflow.t()} | {:error, :not_found}
  def fetch(workflow_id) when is_binary(workflow_id) do
    case Repo.get(Workflow, workflow_id) |> Repo.preload(:steps) do
      nil -> {:error, :not_found}
      wf -> {:ok, wf}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_active(workflow_id) do
    case Repo.get_by(Workflow, id: workflow_id, status: :pending) do
      nil -> {:error, :workflow_not_active}
      wf -> {:ok, wf}
    end
  end

  defp fetch_active_step(workflow_id) do
    step =
      ApprovalStep
      |> where([s], s.workflow_id == ^workflow_id and s.status == :pending)
      |> order_by([s], asc: s.position)
      |> limit(1)
      |> Repo.one()

    if step, do: {:ok, step}, else: {:error, :no_active_step}
  end

  defp assert_authorised(step, approver_id) do
    case Approvals.Roles.has_role?(approver_id, step.required_role) do
      true -> :ok
      false -> {:error, :not_authorised}
    end
  end

  defp assert_not_voted(step, approver_id) do
    already =
      Approval
      |> where([a], a.step_id == ^step.id and a.approver_id == ^approver_id)
      |> Repo.exists?()

    if already, do: {:error, :already_voted}, else: :ok
  end

  defp record_decision(workflow, step, approver_id, decision) do
    Multi.new()
    |> Multi.insert(:approval, Approval.changeset(%Approval{}, %{
         step_id: step.id,
         approver_id: approver_id,
         decision: decision
       }))
    |> Multi.run(:advance, fn repo, _ ->
      advance_if_complete(repo, workflow, step, decision)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{advance: wf}} -> {:ok, wf}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp advance_if_complete(repo, workflow, step, :rejected) do
    step |> ApprovalStep.status_changeset(:rejected) |> repo.update()
    wf = workflow |> Workflow.status_changeset(:rejected) |> repo.update!()
    {:ok, wf}
  end

  defp advance_if_complete(repo, workflow, step, :approved) do
    approval_count = repo.aggregate(from(a in Approval, where: a.step_id == ^step.id and a.decision == :approved), :count, :id)
    required = Approvals.Templates.required_approvals(step)

    if approval_count >= required do
      step |> ApprovalStep.status_changeset(:approved) |> repo.update()

      next_step =
        ApprovalStep
        |> where([s], s.workflow_id == ^workflow.id and s.position > ^step.position)
        |> order_by([s], asc: s.position)
        |> limit(1)
        |> repo.one()

      if next_step do
        {:ok, workflow}
      else
        wf = workflow |> Workflow.status_changeset(:approved) |> repo.update!()
        {:ok, wf}
      end
    else
      {:ok, workflow}
    end
  end
end
```
