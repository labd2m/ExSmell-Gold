```elixir
defmodule Analytics.MapReduce do
  @moduledoc """
  A configurable concurrent map-reduce pipeline for in-process data
  aggregation. The map phase is executed in parallel across `Task.Supervisor`
  workers; the reduce phase runs sequentially after all map tasks complete.
  Each pipeline is constructed from a plain configuration struct, making the
  computation fully composable and testable without spawning workers.
  """

  require Logger

  @type mapper(a, b) :: (a -> b)
  @type reducer(b, acc) :: (b, acc -> acc)
  @type pipeline_opts :: [
          max_concurrency: pos_integer(),
          timeout_ms: pos_integer(),
          supervisor: atom() | pid()
        ]

  @default_concurrency 8
  @default_timeout_ms 30_000

  @doc """
  Runs `items` through the `mapper` function concurrently, then reduces
  results with `reducer` starting from `initial_acc`.
  Returns `{:ok, result}` or `{:error, reason}`.

  Items that raise during mapping are counted as errors. If any mapper
  task times out the entire pipeline returns `{:error, :timeout}`.
  """
  @spec run([a], mapper(a, b), reducer(b, acc), acc, pipeline_opts()) ::
          {:ok, acc} | {:error, term()}
        when a: term(), b: term(), acc: term()
  def run(items, mapper, reducer, initial_acc, opts \\ [])
      when is_list(items) and is_function(mapper, 1) and is_function(reducer, 2) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_concurrency)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    supervisor = Keyword.get(opts, :supervisor, Analytics.MapReduceSupervisor)

    map_results = run_map_phase(items, mapper, supervisor, max_concurrency, timeout_ms)

    case classify_results(map_results) do
      {:ok, mapped_values} ->
        result = Enum.reduce(mapped_values, initial_acc, reducer)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Groups `items` by the key returned by `key_fn`, then runs a separate
  reduce for each group. Returns `{:ok, %{key => reduced_value}}`.
  """
  @spec group_reduce([a], (a -> key), reducer(a, acc), acc, pipeline_opts()) ::
          {:ok, %{term() => acc}} | {:error, term()}
        when a: term(), key: term(), acc: term()
  def group_reduce(items, key_fn, reducer, initial_acc, opts \\ [])
      when is_list(items) and is_function(key_fn, 1) and is_function(reducer, 2) do
    grouped = Enum.group_by(items, key_fn)

    results =
      Task.async_stream(
        grouped,
        fn {key, group} ->
          {key, Enum.reduce(group, initial_acc, reducer)}
        end,
        max_concurrency: Keyword.get(opts, :max_concurrency, @default_concurrency),
        timeout: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    case classify_results(results) do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp run_map_phase(items, mapper, supervisor, max_concurrency, timeout_ms) do
    Task.Supervisor.async_stream(
      supervisor,
      items,
      fn item ->
        try do
          {:ok, mapper.(item)}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp classify_results(results) do
    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, {:ok, _}} -> true
        _ -> false
      end)

    timeout_count = Enum.count(results, &match?({:exit, :timeout}, &1))
    error_count = Enum.count(failures)

    if timeout_count > 0 do
      Logger.error("MapReduce pipeline timed out", timeout_tasks: timeout_count)
      {:error, :timeout}
    else
      if error_count > 0 do
        Logger.warning("MapReduce pipeline had map errors", error_count: error_count)
      end

      values = Enum.map(successes, fn {:ok, {:ok, value}} -> value end)
      {:ok, values}
    end
  end
end
```
