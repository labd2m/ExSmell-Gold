```elixir
defmodule Workflow.Engine.StepRunner do
  @moduledoc """
  Executes a sequential list of workflow steps, threading context through each.
  Steps may halt the chain by returning an error; completed steps are recorded.
  """

  @type context :: map()
  @type step :: %{name: String.t(), run: (context() -> {:ok, context()} | {:error, term()})}
  @type run_result :: %{
          status: :completed | :failed,
          context: context(),
          completed_steps: [String.t()],
          failed_step: String.t() | nil,
          error: term() | nil
        }

  @doc """
  Runs all `steps` in order, passing context from one step to the next.

  Stops on the first failed step. Returns a detailed run result map.
  """
  @spec run([step()], context()) :: run_result()
  def run(steps, initial_context) when is_list(steps) and is_map(initial_context) do
    initial_acc = %{
      status: :completed,
      context: initial_context,
      completed_steps: [],
      failed_step: nil,
      error: nil
    }

    Enum.reduce_while(steps, initial_acc, &execute_step/2)
  end

  @doc """
  Returns whether a run result represents full completion.
  """
  @spec completed?(run_result()) :: boolean()
  def completed?(%{status: :completed}), do: true
  def completed?(%{status: :failed}), do: false

  @doc """
  Extracts a value from the final context by key.
  """
  @spec fetch_result(run_result(), atom()) :: {:ok, term()} | {:error, :missing}
  def fetch_result(%{context: ctx}, key) when is_atom(key) do
    case Map.fetch(ctx, key) do
      {:ok, val} -> {:ok, val}
      :error -> {:error, :missing}
    end
  end

  defp execute_step(%{name: name, run: run_fn}, acc) when is_function(run_fn, 1) do
    case run_fn.(acc.context) do
      {:ok, updated_context} ->
        {:cont,
         %{acc | context: updated_context, completed_steps: acc.completed_steps ++ [name]}}

      {:error, reason} ->
        {:halt, %{acc | status: :failed, failed_step: name, error: reason}}
    end
  end
end

defmodule Workflow.Engine.StepBuilder do
  @moduledoc """
  Convenience functions for constructing typed step maps for use with `StepRunner`.
  """

  alias Workflow.Engine.StepRunner

  @doc """
  Builds a named step from a 1-arity function that takes and returns context.
  """
  @spec build(String.t(), (StepRunner.context() -> {:ok, StepRunner.context()} | {:error, term()})) ::
          StepRunner.step()
  def build(name, fun) when is_binary(name) and name != "" and is_function(fun, 1) do
    %{name: name, run: fun}
  end

  @doc """
  Builds a step that sets a fixed key-value pair in the context.
  """
  @spec set_value(String.t(), atom(), term()) :: StepRunner.step()
  def set_value(name, key, value) when is_binary(name) and is_atom(key) do
    build(name, fn ctx -> {:ok, Map.put(ctx, key, value)} end)
  end

  @doc """
  Builds a step that validates a required key exists in the context.
  """
  @spec require_key(String.t(), atom()) :: StepRunner.step()
  def require_key(name, key) when is_binary(name) and is_atom(key) do
    build(name, fn ctx ->
      if Map.has_key?(ctx, key) do
        {:ok, ctx}
      else
        {:error, "required context key #{inspect(key)} is missing"}
      end
    end)
  end
end
```
