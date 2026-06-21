# File: `example_good_200.md`

```elixir
defmodule Workflow.Saga do
  @moduledoc """
  Executes a sequence of steps as a saga, automatically running
  compensating actions in reverse order when any step fails.

  Each step declares both a forward action and a compensation function.
  If the forward pipeline succeeds, compensations are never called.
  If any step fails, all previously completed steps are rolled back
  in LIFO order before the error is returned.
  """

  @type context :: map()

  @type step :: %{
          required(:name) => atom(),
          required(:run) => (context() -> {:ok, context()} | {:error, term()}),
          required(:compensate) => (context() -> :ok)
        }

  @type saga_result ::
          {:ok, context()}
          | {:error, %{step: atom(), reason: term(), context: context()}}

  @doc """
  Runs all steps in sequence, threading context through each forward action.

  On failure, triggers compensations for all completed steps in reverse
  order and returns a structured error containing the failing step name,
  the reason, and the context at the point of failure.
  """
  @spec run([step()], context()) :: saga_result()
  def run(steps, initial_context \\ %{}) when is_list(steps) and is_map(initial_context) do
    execute_forward(steps, initial_context, [])
  end

  @doc """
  Runs compensations for a list of already-completed steps in reverse order.

  Intended for use when partial execution state needs to be rolled back
  outside the main `run/2` flow, e.g. after a process restart.

  Compensation failures are logged but do not raise; all compensations
  are attempted regardless of individual outcomes.
  """
  @spec compensate([step()], context()) :: :ok
  def compensate(completed_steps, context) when is_list(completed_steps) and is_map(context) do
    completed_steps
    |> Enum.reverse()
    |> Enum.each(&run_compensation(&1, context))
  end

  defp execute_forward([], context, _completed) do
    {:ok, context}
  end

  defp execute_forward([step | remaining], context, completed) do
    case run_safely(step.run, context) do
      {:ok, new_context} ->
        execute_forward(remaining, new_context, [step | completed])

      {:error, reason} ->
        compensate(completed, context)
        {:error, %{step: step.name, reason: reason, context: context}}
    end
  end

  defp run_safely(fun, context) do
    try do
      fun.(context)
    rescue
      exception -> {:error, {:exception, Exception.message(exception)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp run_compensation(%{name: name, compensate: compensate_fn}, context) do
    try do
      compensate_fn.(context)
    rescue
      exception ->
        require Logger
        Logger.error("Compensation for #{name} raised: #{Exception.message(exception)}")
    catch
      :exit, reason ->
        require Logger
        Logger.error("Compensation for #{name} exited: #{inspect(reason)}")
    end
  end

  @doc """
  Builds a step map from discrete run and compensate functions.

  Convenience constructor to avoid callers manually building step maps.
  """
  @spec step(atom(), (context() -> {:ok, context()} | {:error, term()}), (context() -> :ok)) ::
          step()
  def step(name, run_fn, compensate_fn)
      when is_atom(name) and is_function(run_fn, 1) and is_function(compensate_fn, 1) do
    %{name: name, run: run_fn, compensate: compensate_fn}
  end

  @doc """
  Returns a no-op compensating function for steps that have no meaningful
  rollback action.
  """
  @spec noop_compensation() :: (context() -> :ok)
  def noop_compensation, do: fn _context -> :ok end
end
```
