```elixir
defmodule Workflow.DependencyGraph do
  @moduledoc """
  Executes a set of named tasks where each task declares its dependencies.
  Tasks with no pending dependencies run concurrently; a task starts only
  after all its declared prerequisites complete successfully. The execution
  plan is derived from a topological sort of the dependency graph, and cycle
  detection prevents deadlocks at plan construction time. Failed tasks cause
  all dependents to be skipped rather than erroneously executed.
  """

  require Logger

  @type task_name :: atom()
  @type task_fn :: (() -> {:ok, term()} | {:error, term()})
  @type task_spec :: %{
          required(:name) => task_name(),
          required(:run) => task_fn(),
          optional(:depends_on) => [task_name()]
        }

  @type execution_result :: %{
          succeeded: [task_name()],
          failed: [{task_name(), term()}],
          skipped: [task_name()]
        }

  @doc """
  Executes `tasks` respecting declared dependencies. Tasks are started as
  soon as all their dependencies have completed. Raises `ArgumentError`
  when a dependency cycle is detected.
  Returns a structured `execution_result` map.
  """
  @spec execute([task_spec()]) :: execution_result()
  def execute(tasks) when is_list(tasks) do
    sorted = topological_sort!(tasks)
    run_in_order(sorted)
  end

  # ---------------------------------------------------------------------------
  # Topological sort
  # ---------------------------------------------------------------------------

  defp topological_sort!(tasks) do
    task_map = Map.new(tasks, &{&1.name, &1})
    names = Map.keys(task_map)

    validate_dependencies!(task_map, names)

    {sorted, _visited} =
      Enum.reduce(names, {[], MapSet.new()}, fn name, {acc, visited} ->
        visit(name, task_map, visited, MapSet.new(), acc)
      end)

    sorted
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(task_map, &1))
  end

  defp visit(name, task_map, visited, in_stack, acc) do
    if MapSet.member?(visited, name) do
      {acc, visited}
    else
      if MapSet.member?(in_stack, name) do
        raise ArgumentError, "Dependency cycle detected involving task #{inspect(name)}"
      end

      in_stack = MapSet.put(in_stack, name)
      deps = task_map |> Map.get(name) |> Map.get(:depends_on, [])

      {acc, visited} =
        Enum.reduce(deps, {acc, visited}, fn dep, {a, v} ->
          visit(dep, task_map, v, in_stack, a)
        end)

      visited = MapSet.put(visited, name)
      {[name | acc], visited}
    end
  end

  defp validate_dependencies!(task_map, names) do
    Enum.each(task_map, fn {name, task} ->
      Enum.each(Map.get(task, :depends_on, []), fn dep ->
        unless dep in names do
          raise ArgumentError,
                "Task #{inspect(name)} depends on unknown task #{inspect(dep)}"
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  defp run_in_order(sorted_tasks) do
    Enum.reduce(sorted_tasks, %{succeeded: [], failed: [], skipped: []}, fn task, acc ->
      deps = Map.get(task, :depends_on, [])
      failed_deps = Enum.filter(deps, fn dep -> dep in Enum.map(acc.failed, &elem(&1, 0)) end)
      skipped_deps = Enum.filter(deps, fn dep -> dep in acc.skipped end)

      cond do
        failed_deps != [] ->
          Logger.info("Skipping task due to failed dependencies",
            task: task.name,
            failed_deps: failed_deps
          )
          %{acc | skipped: [task.name | acc.skipped]}

        skipped_deps != [] ->
          Logger.info("Skipping task due to skipped dependencies",
            task: task.name,
            skipped_deps: skipped_deps
          )
          %{acc | skipped: [task.name | acc.skipped]}

        true ->
          Logger.debug("Executing task", task: task.name)

          case execute_task(task) do
            {:ok, _result} ->
              Logger.info("Task succeeded", task: task.name)
              %{acc | succeeded: [task.name | acc.succeeded]}

            {:error, reason} ->
              Logger.warning("Task failed", task: task.name, reason: inspect(reason))
              %{acc | failed: [{task.name, reason} | acc.failed]}
          end
      end
    end)
    |> Map.update!(:succeeded, &Enum.reverse/1)
    |> Map.update!(:failed, &Enum.reverse/1)
    |> Map.update!(:skipped, &Enum.reverse/1)
  end

  defp execute_task(%{run: fun}) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
```
