```elixir
defmodule Dag.Task do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          depends_on: [atom()],
          run: (map() -> {:ok, term()} | {:error, term()})
        }

  defstruct [:name, :run, depends_on: []]

  @spec new(atom(), [atom()], (map() -> {:ok, term()} | {:error, term()})) :: t()
  def new(name, depends_on \\ [], run_fn) when is_atom(name) and is_list(depends_on) do
    %__MODULE__{name: name, depends_on: depends_on, run: run_fn}
  end
end

defmodule Dag.Executor do
  @moduledoc """
  Executes a directed acyclic graph of named tasks with maximal parallelism.

  Tasks are sorted topologically so each task starts only when all of its
  declared dependencies have completed. Independent tasks at the same depth
  level run concurrently under a supervised `Task.Supervisor`. The results
  map produced by each task is merged and passed to dependent tasks so they
  can consume upstream outputs by name.
  """

  alias Dag.Task

  @type result_map :: %{atom() => term()}
  @type exec_result :: {:ok, result_map()} | {:error, {atom(), term()}, result_map()}

  @spec run([Task.t()], keyword()) :: exec_result()
  def run(tasks, opts \\ []) when is_list(tasks) do
    supervisor = Keyword.get(opts, :supervisor, Dag.TaskSupervisor)
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    with {:ok, ordered_levels} <- topo_sort(tasks) do
      execute_levels(ordered_levels, %{}, supervisor, timeout)
    end
  end

  defp execute_levels([], results, _sup, _timeout), do: {:ok, results}

  defp execute_levels([level | rest], results, supervisor, timeout) do
    level_results =
      level
      |> Task.Supervisor.async_stream_nolink(supervisor, fn task ->
        {task.name, task.run.(results)}
      end, timeout: timeout)
      |> Enum.map(fn
        {:ok, {name, {:ok, value}}} -> {:ok, name, value}
        {:ok, {name, {:error, reason}}} -> {:error, name, reason}
        {:exit, reason} -> {:error, :unknown, {:exit, reason}}
      end)

    case Enum.find(level_results, &match?({:error, _, _}, &1)) do
      {:error, name, reason} ->
        {:error, {name, reason}, results}

      nil ->
        merged = Enum.reduce(level_results, results, fn {:ok, name, value}, acc ->
          Map.put(acc, name, value)
        end)
        execute_levels(rest, merged, supervisor, timeout)
    end
  end

  defp topo_sort(tasks) do
    task_map = Map.new(tasks, fn t -> {t.name, t} end)

    with :ok <- detect_cycles(task_map) do
      levels = build_levels(task_map)
      {:ok, levels}
    end
  end

  defp build_levels(task_map) do
    Enum.reduce_while(Stream.iterate(task_map, & &1), {[], task_map}, fn _, {levels, remaining} ->
      if map_size(remaining) == 0 do
        {:halt, Enum.reverse(levels)}
      else
        ready = Enum.filter(remaining, fn {_name, task} ->
          Enum.all?(task.depends_on, &Map.has_key?(Map.new(levels |> List.flatten(), & &1), &1))
        end)

        next_level = Enum.map(ready, fn {_name, task} -> task end)
        next_remaining = Map.drop(remaining, Enum.map(ready, &elem(&1, 0)))
        {:cont, {[next_level | levels], next_remaining}}
      end
    end)
    |> then(fn
      levels when is_list(levels) -> levels
      {levels, _} -> Enum.reverse(levels)
    end)
  end

  defp detect_cycles(task_map) do
    names = Map.keys(task_map)
    unknown = Enum.reject(names, fn name ->
      Enum.all?(task_map[name].depends_on, &Map.has_key?(task_map, &1))
    end)

    if unknown == [], do: :ok, else: {:error, {:unknown_dependencies, unknown}}
  end
end
```
