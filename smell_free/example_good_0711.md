```elixir
defmodule Platform.DependencyGraph do
  @moduledoc """
  Executes a set of named tasks in topological order based on declared
  dependencies. Tasks with no mutual dependencies run concurrently under
  a Task.Supervisor; tasks that depend on others wait for their
  prerequisites to complete before starting.
  """

  @type task_name :: atom()
  @type task_fn :: (map() -> {:ok, term()} | {:error, term()})
  @type task_spec :: %{
          name: task_name(),
          deps: [task_name()],
          fun: task_fn()
        }
  @type run_result :: {:ok, map()} | {:error, task_name(), term(), map()}

  @doc """
  Executes all tasks in `specs`, respecting dependency order.

  Returns `{:ok, results}` where `results` maps each task name to its
  return value, or `{:error, failed_task, reason, completed_results}`.
  """
  @spec run(Supervisor.supervisor(), [task_spec()], keyword()) :: run_result()
  def run(task_sup, specs, opts \\ []) when is_list(specs) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with :ok <- validate_no_cycles(specs) do
      execute(task_sup, specs, timeout)
    end
  end

  defp execute(task_sup, specs, timeout) do
    task_map = Map.new(specs, &{&1.name, &1})
    execute_wave(task_sup, task_map, %{}, timeout)
  end

  defp execute_wave(_task_sup, task_map, results, _timeout) when map_size(task_map) == 0 do
    {:ok, results}
  end

  defp execute_wave(task_sup, task_map, results, timeout) do
    ready = Enum.filter(task_map, fn {_name, spec} ->
      Enum.all?(spec.deps, &Map.has_key?(results, &1))
    end)

    if ready == [] do
      {:error, :circular_dependency, :unresolvable, results}
    else
      wave_result = run_wave(task_sup, ready, results, timeout)

      case wave_result do
        {:ok, new_results} ->
          remaining = Map.drop(task_map, Enum.map(ready, fn {name, _} -> name end))
          execute_wave(task_sup, remaining, new_results, timeout)

        {:error, _failed, _reason, _partial} = err ->
          err
      end
    end
  end

  defp run_wave(task_sup, ready_specs, results, timeout) do
    tasks =
      Enum.map(ready_specs, fn {name, %{fun: fun}} ->
        task = Task.Supervisor.async_nolink(task_sup, fn -> {name, fun.(results)} end)
        {name, task}
      end)

    Enum.reduce_while(tasks, {:ok, results}, fn {name, task}, {:ok, acc} ->
      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {^name, {:ok, value}}} ->
          {:cont, {:ok, Map.put(acc, name, value)}}

        {:ok, {^name, {:error, reason}}} ->
          {:halt, {:error, name, reason, acc}}

        nil ->
          {:halt, {:error, name, :timeout, acc}}
      end
    end)
  end

  defp validate_no_cycles(specs) do
    graph = Map.new(specs, &{&1.name, &1.deps})

    case find_cycle(graph) do
      nil -> :ok
      cycle -> {:error, {:circular_dependency, cycle}}
    end
  end

  defp find_cycle(graph) do
    Enum.find_value(Map.keys(graph), fn start ->
      visit(graph, start, [], MapSet.new())
    end)
  end

  defp visit(_graph, node, path, visited) when node in path do
    cycle = Enum.drop_while(path, &(&1 != node))
    cycle ++ [node]
  end

  defp visit(_graph, node, _path, visited) when node in visited, do: nil

  defp visit(graph, node, path, visited) do
    deps = Map.get(graph, node, [])
    new_visited = MapSet.put(visited, node)

    Enum.find_value(deps, fn dep ->
      visit(graph, dep, [node | path], new_visited)
    end)
  end
end
```
