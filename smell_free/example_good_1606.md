```elixir
defmodule Pipeline.TaskGraph do
  @moduledoc """
  Executes a directed acyclic graph of named tasks concurrently,
  respecting declared dependencies. Each task receives the outputs of
  its upstream tasks and may run in parallel with independent siblings.
  """

  @type task_name :: atom()
  @type task_fn :: (map() -> {:ok, term()} | {:error, term()})

  @type task_spec :: %{
          name: task_name(),
          depends_on: [task_name()],
          run: task_fn()
        }

  @type graph_result ::
          {:ok, %{task_name() => term()}}
          | {:error, %{failed: task_name(), reason: term(), completed: [task_name()]}}

  @spec run([task_spec()], keyword()) :: graph_result()
  def run(specs, opts \\ []) when is_list(specs) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    index = Map.new(specs, &{&1.name, &1})

    case validate_no_cycles(specs) do
      {:error, reason} -> {:error, reason}
      :ok -> execute_graph(index, timeout)
    end
  end

  @spec execute_graph(%{task_name() => task_spec()}, pos_integer()) :: graph_result()
  defp execute_graph(index, timeout) do
    all_names = Map.keys(index)
    execute_wave(all_names, index, %{}, timeout)
  end

  @spec execute_wave([task_name()], map(), map(), pos_integer()) :: graph_result()
  defp execute_wave([], _index, results, _timeout), do: {:ok, results}

  defp execute_wave(remaining, index, results, timeout) do
    ready = Enum.filter(remaining, fn name ->
      spec = Map.fetch!(index, name)
      Enum.all?(spec.depends_on, &Map.has_key?(results, &1))
    end)

    case ready do
      [] ->
        {:error, %{failed: :deadlock, reason: :circular_dependency, completed: Map.keys(results)}}

      _ ->
        upstream_inputs = Map.take(results, Enum.flat_map(ready, &Map.fetch!(index, &1).depends_on))

        task_results =
          ready
          |> Task.async_stream(
            fn name ->
              spec = Map.fetch!(index, name)
              {name, spec.run.(upstream_inputs)}
            end,
            max_concurrency: length(ready),
            timeout: timeout,
            on_timeout: :kill_task
          )
          |> Enum.map(&extract_task_result/1)

        case find_failure(task_results) do
          {:error, name, reason} ->
            {:error, %{failed: name, reason: reason, completed: Map.keys(results)}}

          :all_ok ->
            new_results =
              Enum.reduce(task_results, results, fn {name, {:ok, value}}, acc ->
                Map.put(acc, name, value)
              end)

            still_remaining = remaining -- ready
            execute_wave(still_remaining, index, new_results, timeout)
        end
    end
  end

  @spec extract_task_result({:ok, {task_name(), term()}} | {:exit, term()}) ::
          {task_name(), {:ok, term()} | {:error, term()}}
  defp extract_task_result({:ok, {name, result}}), do: {name, result}
  defp extract_task_result({:exit, {name, reason}}), do: {name, {:error, {:task_exit, reason}}}
  defp extract_task_result({:exit, reason}), do: {:unknown, {:error, {:task_exit, reason}}}

  @spec find_failure([{task_name(), term()}]) :: {:error, task_name(), term()} | :all_ok
  defp find_failure(results) do
    case Enum.find(results, fn {_name, result} -> match?({:error, _}, result) end) do
      {name, {:error, reason}} -> {:error, name, reason}
      nil -> :all_ok
    end
  end

  @spec validate_no_cycles([task_spec()]) :: :ok | {:error, map()}
  defp validate_no_cycles(specs) do
    graph = Map.new(specs, &{&1.name, &1.depends_on})
    all_names = Map.keys(graph)

    Enum.reduce_while(all_names, :ok, fn name, _ ->
      case dfs_cycle_check(name, graph, MapSet.new(), MapSet.new()) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec dfs_cycle_check(task_name(), map(), MapSet.t(), MapSet.t()) :: :ok | {:error, map()}
  defp dfs_cycle_check(name, graph, visited, stack) do
    cond do
      MapSet.member?(stack, name) ->
        {:error, %{failed: :cycle_detected, reason: name, completed: []}}
      MapSet.member?(visited, name) ->
        :ok
      true ->
        deps = Map.get(graph, name, [])
        new_stack = MapSet.put(stack, name)
        Enum.reduce_while(deps, :ok, fn dep, _ ->
          case dfs_cycle_check(dep, graph, visited, new_stack) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
        end)
    end
  end
end
```
