# File: `example_good_548.md`

```elixir
defmodule Workflow.ParallelExecutor do
  @moduledoc """
  Executes a set of independent workflow branches concurrently,
  collecting their results and merging the returned contexts.

  Branches run under supervised Tasks with a shared deadline. A
  configurable failure strategy controls whether a single branch
  failure aborts all remaining branches or allows them to complete.
  """

  require Logger

  @type context :: map()
  @type branch_name :: atom()
  @type branch_fn :: (context() -> {:ok, context()} | {:error, term()})

  @type branch :: %{
          required(:name) => branch_name(),
          required(:run) => branch_fn()
        }

  @type failure_strategy :: :fail_fast | :collect_all

  @type branch_result :: %{
          name: branch_name(),
          status: :ok | :error | :timeout,
          context_updates: map(),
          error: term() | nil,
          duration_ms: non_neg_integer()
        }

  @type parallel_result :: %{
          merged_context: context(),
          branch_results: [branch_result()],
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          status: :completed | :partial_failure | :failed
        }

  @default_timeout_ms 30_000

  @doc """
  Runs all `branches` concurrently starting from `initial_context`.

  Each branch receives a copy of `initial_context`. The returned
  context updates from successful branches are merged into a final
  context map. Conflicting keys are resolved by taking the last writer
  in alphabetical branch-name order.

  Options:
  - `:timeout_ms` — per-branch deadline (default: 30 000)
  - `:strategy` — `:fail_fast` aborts on first failure; `:collect_all`
    runs all branches regardless (default: `:collect_all`)
  """
  @spec run([branch()], context(), keyword()) :: parallel_result()
  def run(branches, initial_context \\ %{}, opts \\ [])
      when is_list(branches) and is_map(initial_context) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    strategy = Keyword.get(opts, :strategy, :collect_all)

    tasks = Enum.map(branches, &launch_branch(&1, initial_context))
    results = collect_results(tasks, branches, timeout_ms, strategy)
    build_parallel_result(results, initial_context)
  end

  defp launch_branch(%{name: name, run: run_fn}, context) do
    start_ms = System.monotonic_time(:millisecond)
    task = Task.async(fn -> {run_fn.(context), System.monotonic_time(:millisecond) - start_ms} end)
    {name, task, start_ms}
  end

  defp collect_results(tasks, _branches, timeout_ms, :collect_all) do
    Enum.map(tasks, fn {name, task, _start_ms} ->
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {{:ok, ctx_updates}, duration}} ->
          %{name: name, status: :ok, context_updates: ctx_updates, error: nil, duration_ms: duration}

        {:ok, {{:error, reason}, duration}} ->
          Logger.warning("Branch #{name} failed: #{inspect(reason)}")
          %{name: name, status: :error, context_updates: %{}, error: reason, duration_ms: duration}

        nil ->
          Logger.warning("Branch #{name} timed out after #{timeout_ms}ms")
          %{name: name, status: :timeout, context_updates: %{}, error: :timeout, duration_ms: timeout_ms}
      end
    end)
  end

  defp collect_results(tasks, _branches, timeout_ms, :fail_fast) do
    Enum.reduce_while(tasks, [], fn {name, task, _start_ms}, acc ->
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {{:ok, ctx_updates}, duration}} ->
          result = %{name: name, status: :ok, context_updates: ctx_updates, error: nil, duration_ms: duration}
          {:cont, [result | acc]}

        {:ok, {{:error, reason}, duration}} ->
          result = %{name: name, status: :error, context_updates: %{}, error: reason, duration_ms: duration}
          {:halt, [result | acc]}

        nil ->
          result = %{name: name, status: :timeout, context_updates: %{}, error: :timeout, duration_ms: timeout_ms}
          {:halt, [result | acc]}
      end
    end)
    |> Enum.reverse()
  end

  defp build_parallel_result(results, initial_context) do
    succeeded = Enum.count(results, &(&1.status == :ok))
    failed = length(results) - succeeded

    merged_context =
      results
      |> Enum.filter(&(&1.status == :ok))
      |> Enum.sort_by(& Atom.to_string(&1.name))
      |> Enum.reduce(initial_context, fn %{context_updates: updates}, ctx ->
        Map.merge(ctx, updates)
      end)

    status =
      cond do
        failed == 0 -> :completed
        succeeded == 0 -> :failed
        true -> :partial_failure
      end

    %{
      merged_context: merged_context,
      branch_results: results,
      succeeded: succeeded,
      failed: failed,
      status: status
    }
  end
end
```
