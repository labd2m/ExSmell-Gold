```elixir
defmodule Workers.ConcurrentMapper do
  @moduledoc """
  Applies a function to a list of items concurrently using a bounded pool
  of supervised tasks. Results are returned in the same order as the input
  list regardless of completion order. Items that raise or exceed the
  timeout are represented as `{:error, reason}` entries so the full result
  list is always the same length as the input.
  """

  @type mapper_fn :: (term() -> term())
  @type mapper_result :: {:ok, term()} | {:error, term()}
  @type options :: [
          concurrency: pos_integer(),
          timeout_ms: pos_integer(),
          supervisor: atom() | pid()
        ]

  @default_concurrency 10
  @default_timeout_ms 15_000

  @doc """
  Maps `fun` over `items` with bounded concurrency. Returns a list of
  tagged results in input order.
  """
  @spec map([term()], mapper_fn(), options()) :: [mapper_result()]
  def map(items, fun, opts \ [])
      when is_list(items) and is_function(fun, 1) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    supervisor = Keyword.get(opts, :supervisor, Workers.TaskSupervisor)

    items
    |> Enum.with_index()
    |> Enum.chunk_every(concurrency)
    |> Enum.flat_map(fn batch ->
      batch
      |> Enum.map(fn {item, idx} ->
        task = Task.Supervisor.async_nolink(supervisor, fn -> fun.(item) end)
        {idx, task}
      end)
      |> Enum.map(fn {idx, task} -> {idx, collect(task, timeout_ms)} end)
    end)
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, result} -> result end)
  end

  @doc """
  Like `map/3` but filters out error results and returns only successful values.
  """
  @spec filter_map([term()], mapper_fn(), options()) :: [term()]
  def filter_map(items, fun, opts \ []) do
    items
    |> map(fun, opts)
    |> Enum.flat_map(fn
      {:ok, value} -> [value]
      {:error, _} -> []
    end)
  end

  @doc "Returns a summary of succeeded and failed counts over a result list."
  @spec summarise([mapper_result()]) :: %{succeeded: non_neg_integer(), failed: non_neg_integer()}
  def summarise(results) when is_list(results) do
    Enum.reduce(results, %{succeeded: 0, failed: 0}, fn
      {:ok, _}, acc -> Map.update!(acc, :succeeded, &(&1 + 1))
      {:error, _}, acc -> Map.update!(acc, :failed, &(&1 + 1))
    end)
  end

  defp collect(task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:task_exit, reason}}
      nil -> {:error, :timeout}
    end
  end
end
```
