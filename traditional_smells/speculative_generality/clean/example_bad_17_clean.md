```elixir
defmodule Scheduling.TaskManager do
  @moduledoc """
  Manages the full lifecycle of scheduled background tasks: creation,
  execution dispatch, retry handling, and completion tracking.
  """

  alias Scheduling.{Task, TaskLog, Repo}

  @max_retries       3
  @retry_backoff_sec 30

  def create_task(type, payload, run_at) do
    attrs = %{
      type:        type,
      payload:     payload,
      status:      :scheduled,
      run_at:      run_at,
      attempts:    0,
      max_retries: @max_retries,
      created_at:  DateTime.utc_now()
    }

    case Task.changeset(%Task{}, attrs) |> Repo.insert() do
      {:ok, task}  -> {:ok, task}
      {:error, cs} -> {:error, cs}
    end
  end

  def create_immediate(type, payload) do
    create_task(type, payload, DateTime.utc_now())
  end

  def dispatch_due_tasks do
    now = DateTime.utc_now()

    Task
    |> Repo.all()
    |> Enum.filter(fn t ->
      t.status == :scheduled and
        DateTime.compare(t.run_at, now) in [:lt, :eq]
    end)
    |> Enum.each(&execute_task/1)
  end

  def retry_failed do
    Task
    |> Repo.all()
    |> Enum.filter(fn t ->
      t.status == :failed and t.attempts < t.max_retries
    end)
    |> Enum.each(fn task ->
      backoff = task.attempts * @retry_backoff_sec
      run_at  = DateTime.add(DateTime.utc_now(), backoff, :second)

      task
      |> Task.changeset(%{status: :scheduled, run_at: run_at})
      |> Repo.update()
    end)
  end

  def cancel_task(task_id) do
    task = Repo.get!(Task, task_id)

    if task.status in [:scheduled, :pending] do
      task
      |> Task.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :cannot_cancel}
    end
  end

  def task_status(task_id) do
    task = Repo.get!(Task, task_id)
    Map.take(task, [:id, :type, :status, :attempts, :run_at, :completed_at])
  end

  def task_stats do
    tasks = Repo.all(Task)

    %{
      total:     length(tasks),
      scheduled: Enum.count(tasks, &(&1.status == :scheduled)),
      running:   Enum.count(tasks, &(&1.status == :running)),
      completed: Enum.count(tasks, &(&1.status == :completed)),
      failed:    Enum.count(tasks, &(&1.status == :failed)),
      cancelled: Enum.count(tasks, &(&1.status == :cancelled))
    }
  end


  defp execute_task(task) do
    task
    |> Task.changeset(%{status: :running, started_at: DateTime.utc_now()})
    |> Repo.update!()

    TaskLog.record!(:started, task.id)

    try do
      apply(String.to_existing_atom("Elixir.Workers.#{Macro.camelize(to_string(task.type))}"), :run, [task.payload])

      task
      |> Task.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
      |> Repo.update!()

      TaskLog.record!(:completed, task.id)
    rescue
      error ->
        task
        |> Task.changeset(%{
          status:    :failed,
          attempts:  task.attempts + 1,
          error_msg: Exception.message(error)
        })
        |> Repo.update!()

        TaskLog.record!(:failed, task.id)
    end
  end
end

defmodule Scheduling.WorkflowOrchestrator do
  @moduledoc """
  Orchestrates multi-step workflows composed of dependent tasks.
  Manages execution order, dependency resolution, and workflow-level
  status tracking for complex asynchronous pipelines.
  """

  alias Scheduling.{Workflow, WorkflowStep, Repo}

  def create_workflow(name, steps) when is_list(steps) do
    attrs = %{
      name:       name,
      status:     :pending,
      steps:      steps,
      created_at: DateTime.utc_now()
    }

    Workflow.changeset(%Workflow{}, attrs) |> Repo.insert()
  end

  def start_workflow(workflow_id) do
    workflow        = Repo.get!(Workflow, workflow_id)
    initial_steps   = Enum.filter(workflow.steps, &Enum.empty?(&1.depends_on))

    Enum.each(initial_steps, &schedule_step/1)

    workflow
    |> Workflow.changeset(%{status: :running, started_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def advance_workflow(workflow_id, completed_step_id) do
    workflow = Repo.get!(Workflow, workflow_id)

    next_steps =
      Enum.filter(workflow.steps, fn step ->
        step.status == :pending and
          Enum.all?(step.depends_on, fn dep_id ->
            Enum.any?(workflow.steps, &(&1.id == dep_id and &1.status == :completed))
          end)
      end)

    Enum.each(next_steps, &schedule_step/1)

    if all_completed?(workflow) do
      workflow
      |> Workflow.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  def workflow_status(workflow_id) do
    workflow = Repo.get!(Workflow, workflow_id)

    %{
      id:        workflow.id,
      name:      workflow.name,
      status:    workflow.status,
      total:     length(workflow.steps),
      completed: Enum.count(workflow.steps, &(&1.status == :completed)),
      pending:   Enum.count(workflow.steps, &(&1.status == :pending)),
      failed:    Enum.count(workflow.steps, &(&1.status == :failed))
    }
  end


  defp schedule_step(step) do
    step
    |> WorkflowStep.changeset(%{status: :scheduled, scheduled_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp all_completed?(workflow) do
    Enum.all?(workflow.steps, &(&1.status == :completed))
  end
end
```
