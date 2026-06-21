```elixir
defmodule Files.BatchProcessor do
  @moduledoc """
  Processes a list of file paths concurrently using a Task.Supervisor.
  Each file is handled in its own supervised task. Results are collected
  in input order and returned as tagged tuples. Batch sizes and timeout
  are configurable per call.
  """

  @type file_path :: Path.t()
  @type processor_fn :: (file_path() -> {:ok, term()} | {:error, term()})
  @type batch_result :: [{:ok, term()} | {:error, term()}]
  @type summary :: %{succeeded: non_neg_integer(), failed: non_neg_integer()}

  @default_timeout_ms 30_000
  @default_concurrency 10

  @doc """
  Processes `paths` concurrently by invoking `processor_fn` for each one.
  `max_concurrency` bounds the number of simultaneous tasks. Results are
  returned in the same order as the input list.
  """
  @spec process(pid() | atom(), [file_path()], processor_fn(), keyword()) :: batch_result()
  def process(supervisor, paths, processor_fn, opts \\ [])
      when is_list(paths) and is_function(processor_fn, 1) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    concurrency = Keyword.get(opts, :max_concurrency, @default_concurrency)

    paths
    |> Enum.chunk_every(concurrency)
    |> Enum.flat_map(fn batch -> run_batch(supervisor, batch, processor_fn, timeout) end)
  end

  @doc """
  Summarizes a batch result list into counts of succeeded and failed items.
  """
  @spec summarize(batch_result()) :: summary()
  def summarize(results) when is_list(results) do
    Enum.reduce(results, %{succeeded: 0, failed: 0}, fn
      {:ok, _}, acc -> Map.update!(acc, :succeeded, &(&1 + 1))
      {:error, _}, acc -> Map.update!(acc, :failed, &(&1 + 1))
    end)
  end

  @doc "Extracts successful values from a batch result list."
  @spec successful_values(batch_result()) :: [term()]
  def successful_values(results) when is_list(results) do
    for {:ok, value} <- results, do: value
  end

  @doc "Extracts failure reasons from a batch result list."
  @spec failure_reasons(batch_result()) :: [term()]
  def failure_reasons(results) when is_list(results) do
    for {:error, reason} <- results, do: reason
  end

  defp run_batch(supervisor, batch, processor_fn, timeout) do
    batch
    |> Enum.map(fn path ->
      Task.Supervisor.async_nolink(supervisor, fn -> processor_fn.(path) end)
    end)
    |> Enum.map(&collect_task_result(&1, timeout))
  end

  defp collect_task_result(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:task_crashed, reason}}
      nil -> {:error, :timeout}
    end
  end
end
```
