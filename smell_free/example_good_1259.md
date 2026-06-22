```elixir
defmodule Workflow.Step do
  @moduledoc """
  Describes a single named step in an execution workflow.
  Each step holds a reference to a module that implements the
  `Workflow.Runnable` behaviour.
  """

  @enforce_keys [:name, :module]
  defstruct [:name, :module, :opts, :on_failure]

  @type on_failure_strategy :: :halt | :skip | :retry
  @type t :: %__MODULE__{
          name: atom(),
          module: module(),
          opts: keyword(),
          on_failure: on_failure_strategy()
        }

  @spec new(atom(), module(), keyword()) :: t()
  def new(name, module, opts \\ []) when is_atom(name) and is_atom(module) do
    %__MODULE__{
      name: name,
      module: module,
      opts: Keyword.drop(opts, [:on_failure]),
      on_failure: Keyword.get(opts, :on_failure, :halt)
    }
  end
end

defmodule Workflow.Runnable do
  @moduledoc """
  Behaviour that all workflow step modules must implement.
  """

  @callback run(context :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, atom(), String.t()}
end

defmodule Workflow.Result do
  @moduledoc """
  Accumulates per-step outcomes for a completed workflow run.
  """

  @enforce_keys [:workflow_id, :status, :step_results]
  defstruct [:workflow_id, :status, :step_results, :completed_at]

  @type step_result :: %{name: atom(), status: :ok | :skipped | :failed, detail: term()}
  @type t :: %__MODULE__{
          workflow_id: String.t(),
          status: :completed | :halted,
          step_results: list(step_result()),
          completed_at: DateTime.t()
        }
end

defmodule Workflow.Runner do
  @moduledoc """
  Executes a sequence of `Workflow.Step` definitions against a shared
  context map. Context is threaded through each step, allowing steps
  to pass data downstream. Failure handling follows each step's configured
  strategy: `:halt` aborts the run, `:skip` continues, `:retry` attempts once more.
  """

  alias Workflow.{Step, Result}

  @type workflow_id :: String.t()

  @spec run(workflow_id(), list(Step.t()), map()) :: Result.t()
  def run(workflow_id, steps, initial_context \\ %{})
      when is_binary(workflow_id) and is_list(steps) and is_map(initial_context) do
    {final_context, step_results, status} =
      Enum.reduce_while(steps, {initial_context, [], :completed}, &execute_step/2)

    %Result{
      workflow_id: workflow_id,
      status: status,
      step_results: Enum.reverse(step_results),
      completed_at: DateTime.utc_now()
    }
  end

  defp execute_step(%Step{} = step, {ctx, results, _status}) do
    case attempt(step, ctx) do
      {:ok, new_ctx} ->
        result = %{name: step.name, status: :ok, detail: nil}
        {:cont, {new_ctx, [result | results], :completed}}

      {:error, reason, detail} ->
        handle_failure(step, reason, detail, ctx, results)
    end
  end

  defp attempt(%Step{module: mod, opts: opts}, ctx) do
    mod.run(ctx, opts)
  rescue
    err -> {:error, :exception, Exception.message(err)}
  end

  defp handle_failure(%Step{on_failure: :halt} = step, reason, detail, _ctx, results) do
    result = %{name: step.name, status: :failed, detail: {reason, detail}}
    {:halt, {%{}, [result | results], :halted}}
  end

  defp handle_failure(%Step{on_failure: :skip} = step, reason, detail, ctx, results) do
    result = %{name: step.name, status: :skipped, detail: {reason, detail}}
    {:cont, {ctx, [result | results], :completed}}
  end

  defp handle_failure(%Step{on_failure: :retry} = step, _reason, _detail, ctx, results) do
    case attempt(step, ctx) do
      {:ok, new_ctx} ->
        result = %{name: step.name, status: :ok, detail: :retried}
        {:cont, {new_ctx, [result | results], :completed}}

      {:error, reason, detail} ->
        result = %{name: step.name, status: :failed, detail: {reason, detail}}
        {:halt, {%{}, [result | results], :halted}}
    end
  end
end
```
