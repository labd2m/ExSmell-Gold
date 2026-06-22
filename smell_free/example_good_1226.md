```elixir
defmodule Bulk.Operation do
  @moduledoc """
  Runs a batched operation over a large list of inputs, collecting
  per-item success and failure outcomes without aborting on partial errors.
  Execution is concurrent per batch using supervised tasks.
  """

  @type item :: term()
  @type item_result :: {:ok, term()} | {:error, term()}
  @type run_result :: %{
          total: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          failures: list(%{item: item(), reason: term()})
        }

  @default_batch_size 50
  @default_concurrency System.schedulers_online()
  @task_timeout_ms 15_000

  @spec run(list(item()), (item() -> item_result()), keyword()) :: run_result()
  def run(items, operation_fn, opts \\ [])
      when is_list(items) and is_function(operation_fn, 1) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    items
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce(empty_result(), fn batch, acc ->
      batch_results = execute_batch(batch, operation_fn, concurrency)
      merge_results(acc, batch_results)
    end)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  defp execute_batch(batch, operation_fn, concurrency) do
    batch
    |> Task.async_stream(
      fn item -> {item, operation_fn.(item)} end,
      max_concurrency: concurrency,
      timeout: @task_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(empty_result(), &accumulate_task_result/2)
  end

  defp accumulate_task_result({:ok, {_item, {:ok, _}}}, acc) do
    Map.update!(acc, :succeeded, &(&1 + 1))
  end

  defp accumulate_task_result({:ok, {item, {:error, reason}}}, acc) do
    acc
    |> Map.update!(:failed, &(&1 + 1))
    |> Map.update!(:failures, &[%{item: item, reason: reason} | &1])
  end

  defp accumulate_task_result({:exit, reason}, acc) do
    acc
    |> Map.update!(:failed, &(&1 + 1))
    |> Map.update!(:failures, &[%{item: :unknown, reason: {:task_exit, reason}} | &1])
  end

  defp merge_results(base, addition) do
    %{
      total: base.total + addition.succeeded + addition.failed,
      succeeded: base.succeeded + addition.succeeded,
      failed: base.failed + addition.failed,
      failures: addition.failures ++ base.failures
    }
  end

  defp empty_result do
    %{total: 0, succeeded: 0, failed: 0, failures: []}
  end
end

defmodule Bulk.Idempotent do
  @moduledoc """
  Wraps a bulk operation function so that already-processed items (tracked
  by a caller-supplied key function) are skipped rather than re-executed.
  The processed set is maintained per call and is not persisted.
  """

  alias Bulk.Operation

  @spec run(list(term()), (term() -> term()), (term() -> Operation.item_result()), keyword()) ::
          Operation.run_result()
  def run(items, key_fn, operation_fn, opts \\ [])
      when is_list(items) and is_function(key_fn, 1) and is_function(operation_fn, 1) do
    {unique_items, skipped} = deduplicate(items, key_fn)

    result = Operation.run(unique_items, operation_fn, opts)

    Map.update!(result, :total, &(&1 + skipped))
  end

  defp deduplicate(items, key_fn) do
    {unique, seen, skipped} =
      Enum.reduce(items, {[], MapSet.new(), 0}, fn item, {acc, seen, skip} ->
        key = key_fn.(item)

        if MapSet.member?(seen, key) do
          {acc, seen, skip + 1}
        else
          {[item | acc], MapSet.put(seen, key), skip}
        end
      end)

    {Enum.reverse(unique), skipped}
  end
end
```
