# File: `example_good_93.md`

```elixir
defmodule Workflow.StepRunner do
  @moduledoc """
  Executes a named sequence of workflow steps, threading context through
  each stage and collecting a structured execution record.

  Steps are plain functions with a defined contract. The runner handles
  sequencing, early exit on failure, and result aggregation without
  embedding any domain logic itself.
  """

  @type step_name :: atom()
  @type context :: map()

  @type step_fn :: (context() -> {:ok, context()} | {:error, term()})

  @type step :: %{
          required(:name) => step_name(),
          required(:run) => step_fn(),
          optional(:on_error) => :halt | :continue
        }

  @type step_result :: %{
          name: step_name(),
          status: :ok | :skipped | :failed,
          error: term() | nil,
          duration_ms: non_neg_integer()
        }

  @type run_result :: %{
          status: :completed | :failed,
          final_context: context(),
          steps: [step_result()],
          total_duration_ms: non_neg_integer()
        }

  @doc """
  Runs all steps in order, threading the context through each one.

  A step may update the context by returning `{:ok, new_context}`.
  When a step returns `{:error, reason}` and its `:on_error` is `:halt`
  (the default), execution stops and subsequent steps are marked as
  `:skipped`. Steps with `:on_error: :continue` allow the run to proceed
  despite failure.

  Returns a `run_result` describing the full execution trace.
  """
  @spec run([step()], context()) :: run_result()
  def run(steps, initial_context \\ %{}) when is_list(steps) and is_map(initial_context) do
    run_start = System.monotonic_time(:millisecond)

    {final_context, step_results, run_failed} =
      Enum.reduce(steps, {initial_context, [], false}, &execute_step/2)

    total_ms = System.monotonic_time(:millisecond) - run_start
    status = if run_failed, do: :failed, else: :completed

    %{
      status: status,
      final_context: final_context,
      steps: Enum.reverse(step_results),
      total_duration_ms: total_ms
    }
  end

  defp execute_step(_step, {ctx, results, true = halted}) do
    {ctx, results, halted}
  end

  defp execute_step(%{name: name, run: run_fn} = step, {ctx, results, false}) do
    on_error = Map.get(step, :on_error, :halt)
    step_start = System.monotonic_time(:millisecond)

    case run_step_safely(run_fn, ctx) do
      {:ok, new_ctx} ->
        result = build_result(name, :ok, nil, step_start)
        {new_ctx, [result | results], false}

      {:error, reason} ->
        result = build_result(name, :failed, reason, step_start)
        halted = on_error == :halt
        {ctx, [result | results], halted}
    end
  end

  defp run_step_safely(run_fn, ctx) do
    try do
      run_fn.(ctx)
    rescue
      exception -> {:error, {:exception, Exception.message(exception)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp build_result(name, status, error, step_start) do
    %{
      name: name,
      status: status,
      error: error,
      duration_ms: System.monotonic_time(:millisecond) - step_start
    }
  end

  @doc """
  Returns a human-readable summary of a run result for logging purposes.
  """
  @spec summarize(run_result()) :: String.t()
  def summarize(%{status: status, steps: steps, total_duration_ms: total_ms}) do
    step_summary =
      Enum.map_join(steps, ", ", fn %{name: name, status: s} ->
        "#{name}=#{s}"
      end)

    "Workflow #{status} in #{total_ms}ms [#{step_summary}]"
  end

  @doc """
  Returns only the failed step results from a run, if any.
  """
  @spec failed_steps(run_result()) :: [step_result()]
  def failed_steps(%{steps: steps}) do
    Enum.filter(steps, fn step -> step.status == :failed end)
  end
end
```
