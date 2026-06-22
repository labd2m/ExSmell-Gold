```elixir
defmodule Ingest.ParallelPipeline do
  @moduledoc """
  Concurrent data ingestion pipeline built on supervised Task processes.

  Records are partitioned into configurable batches and processed in
  parallel. Each batch runs inside its own Task and results are collected
  after all tasks complete or the global timeout elapses. Partial failures
  do not abort the pipeline; they are accumulated in the failure summary.
  """

  require Logger

  @type raw_record :: map()
  @type processed_record :: map()
  @type pipeline_result :: %{succeeded: [processed_record()], failed: [term()]}

  @default_batch_size 50
  @default_timeout_ms 30_000

  @doc """
  Processes `records` through the full ingestion pipeline concurrently.

  Returns a summary map with `:succeeded` processed records and `:failed`
  error terms. Accepts `:batch_size` and `:timeout_ms` keyword options.
  """
  @spec run([raw_record()], keyword()) :: pipeline_result()
  def run(records, opts \\ []) when is_list(records) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    records
    |> Enum.chunk_every(batch_size)
    |> dispatch_batches(timeout)
    |> collect_results()
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp dispatch_batches(batches, timeout) do
    batches
    |> Enum.map(fn batch -> Task.async(fn -> process_batch(batch) end) end)
    |> Task.yield_many(timeout)
    |> Enum.map(&extract_task_result/1)
  end

  defp process_batch(records) do
    results = Enum.map(records, &transform_record/1)
    {:ok, results}
  rescue
    error -> {:error, error}
  end

  defp transform_record(record) do
    record
    |> validate_record()
    |> normalize_fields()
    |> enrich_record()
  end

  defp validate_record(%{id: _, type: _, payload: _} = record) when is_map(record),
    do: {:ok, record}

  defp validate_record(record),
    do: {:error, {:invalid_record_shape, record}}

  defp normalize_fields({:error, _} = error), do: error

  defp normalize_fields({:ok, record}) do
    normalized = Map.update!(record, :type, &String.downcase/1)
    {:ok, normalized}
  end

  defp enrich_record({:error, _} = error), do: error

  defp enrich_record({:ok, record}) do
    enriched = Map.put(record, :processed_at, DateTime.utc_now())
    {:ok, enriched}
  end

  defp extract_task_result({_task, {:ok, result}}), do: result

  defp extract_task_result({task, nil}) do
    Task.shutdown(task, :brutal_kill)
    {:error, :batch_timeout}
  end

  defp extract_task_result({_task, {:exit, reason}}), do: {:error, {:batch_exit, reason}}

  defp collect_results(batch_outcomes) do
    batch_outcomes
    |> Enum.flat_map(&flatten_batch/1)
    |> Enum.reduce(%{succeeded: [], failed: []}, &accumulate/2)
    |> reverse_accumulators()
  end

  defp flatten_batch({:ok, records}), do: records
  defp flatten_batch({:error, _} = err), do: [err]

  defp accumulate({:ok, record}, acc), do: %{acc | succeeded: [record | acc.succeeded]}
  defp accumulate({:error, reason}, acc), do: %{acc | failed: [reason | acc.failed]}

  defp reverse_accumulators(acc) do
    %{succeeded: Enum.reverse(acc.succeeded), failed: Enum.reverse(acc.failed)}
  end
end
```
