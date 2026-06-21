```elixir
defmodule MyApp.Workflow.StepRunner do
  @moduledoc """
  Executes an ordered sequence of workflow steps, threading context
  through each step via a typed `%WorkflowContext{}` struct. Steps are
  plain modules implementing the `MyApp.Workflow.Step` behaviour.

  Execution halts on the first failing step and returns a structured
  error tuple that names the failing step, preserving whatever partial
  context was accumulated up to that point for diagnostics.
  """

  alias MyApp.Workflow.WorkflowContext

  @type step_module :: module()
  @type run_result ::
          {:ok, WorkflowContext.t()}
          | {:error, %{step: step_module(), reason: term(), context: WorkflowContext.t()}}

  @doc """
  Runs `steps` in sequence, passing the result context of each step
  into the next. Returns `{:ok, final_context}` or a structured error
  halting at the first failure.
  """
  @spec run([step_module()], WorkflowContext.t()) :: run_result()
  def run(steps, %WorkflowContext{} = initial_context) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, initial_context}, fn step, {:ok, ctx} ->
      case execute_step(step, ctx) do
        {:ok, new_ctx} ->
          {:cont, {:ok, new_ctx}}

        {:error, reason} ->
          {:halt, {:error, %{step: step, reason: reason, context: ctx}}}
      end
    end)
  end

  @doc """
  Runs `steps` and applies `on_error` with the failure map when any step
  fails. The compensating function receives the same map returned in the
  error tuple, enabling rollback or notification side-effects.
  """
  @spec run_with_compensation(
          [step_module()],
          WorkflowContext.t(),
          (map() -> :ok)
        ) :: run_result()
  def run_with_compensation(steps, context, on_error)
      when is_list(steps) and is_function(on_error, 1) do
    case run(steps, context) do
      {:ok, _} = success ->
        success

      {:error, failure} = error ->
        on_error.(failure)
        error
    end
  end

  @spec execute_step(step_module(), WorkflowContext.t()) ::
          {:ok, WorkflowContext.t()} | {:error, term()}
  defp execute_step(step, context) do
    step.execute(context)
  rescue
    exception ->
      require Logger
      Logger.error("workflow_step_exception",
        step: step,
        exception: Exception.message(exception),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      {:error, {:exception, Exception.message(exception)}}
  end
end

defmodule MyApp.Workflow.WorkflowContext do
  @moduledoc "Carries state through a workflow execution pipeline."

  @enforce_keys [:workflow_id, :payload]
  defstruct [:workflow_id, :payload, metadata: %{}, completed_steps: []]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          payload: map(),
          metadata: map(),
          completed_steps: [module()]
        }

  @doc "Records a completed step in the context."
  @spec mark_complete(__MODULE__.t(), module()) :: __MODULE__.t()
  def mark_complete(%__MODULE__{} = ctx, step) do
    %{ctx | completed_steps: [step | ctx.completed_steps]}
  end

  @doc "Merges additional metadata into the context."
  @spec put_meta(__MODULE__.t(), map()) :: __MODULE__.t()
  def put_meta(%__MODULE__{} = ctx, meta) when is_map(meta) do
    %{ctx | metadata: Map.merge(ctx.metadata, meta)}
  end
end

defmodule MyApp.Workflow.Step do
  @moduledoc "Behaviour contract for workflow step modules."

  @callback execute(MyApp.Workflow.WorkflowContext.t()) ::
              {:ok, MyApp.Workflow.WorkflowContext.t()} | {:error, term()}
end
```
