**File:** `example_good_1413.md`

```elixir
defmodule BulkProcessor.ItemResult do
  @moduledoc "Represents the processing outcome for a single item in a bulk operation."

  @enforce_keys [:index, :status]
  defstruct [:index, :status, :output, :error, :input]

  @type status :: :ok | :error | :skipped
  @type t :: %__MODULE__{
          index: non_neg_integer(),
          status: status(),
          output: term(),
          error: term() | nil,
          input: term()
        }

  @spec success(non_neg_integer(), term(), term()) :: t()
  def success(index, input, output) do
    %__MODULE__{index: index, status: :ok, output: output, error: nil, input: input}
  end

  @spec failure(non_neg_integer(), term(), term()) :: t()
  def failure(index, input, error) do
    %__MODULE__{index: index, status: :error, output: nil, error: error, input: input}
  end

  @spec skipped(non_neg_integer(), term(), term()) :: t()
  def skipped(index, input, reason) do
    %__MODULE__{index: index, status: :skipped, output: nil, error: reason, input: input}
  end
end

defmodule BulkProcessor.Summary do
  @moduledoc "Aggregated summary statistics for a completed bulk operation."

  @enforce_keys [:total, :succeeded, :failed, :skipped, :duration_ms]
  defstruct [:total, :succeeded, :failed, :skipped, :duration_ms, :results]

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          duration_ms: non_neg_integer(),
          results: [BulkProcessor.ItemResult.t()]
        }
end

defmodule BulkProcessor do
  @moduledoc """
  Processes a list of items through a configurable pipeline of operations:
  an optional guard predicate, a transformation function, and an optional
  side-effecting action. Collects per-item results and returns a full summary.
  Supports both sequential and concurrent processing modes.
  """

  alias BulkProcessor.{ItemResult, Summary}

  @type item_handler :: (term() -> {:ok, term()} | {:error, term()})
  @type item_guard :: (term() -> boolean())

  @type config :: %{
          handler: item_handler(),
          guard: item_guard() | nil,
          concurrency: pos_integer()
        }

  @spec process([term()], config()) :: Summary.t()
  def process(items, config) when is_list(items) do
    started_at = System.monotonic_time(:millisecond)
    concurrency = Map.get(config, :concurrency, 1)

    results =
      items
      |> Enum.with_index()
      |> process_items(config, concurrency)
      |> Enum.sort_by(& &1.index)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    %Summary{
      total: length(items),
      succeeded: Enum.count(results, &(&1.status == :ok)),
      failed: Enum.count(results, &(&1.status == :error)),
      skipped: Enum.count(results, &(&1.status == :skipped)),
      duration_ms: duration_ms,
      results: results
    }
  end

  defp process_items(indexed_items, config, 1) do
    Enum.map(indexed_items, fn {item, index} ->
      process_single(item, index, config)
    end)
  end

  defp process_items(indexed_items, config, concurrency) do
    indexed_items
    |> Task.async_stream(
      fn {item, index} -> process_single(item, index, config) end,
      max_concurrency: concurrency,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, result} -> [result]
      {:exit, reason} ->
        [ItemResult.failure(0, nil, {:task_crashed, reason})]
    end)
  end

  defp process_single(item, index, config) do
    guard = Map.get(config, :guard)

    if guard != nil and not guard.(item) do
      ItemResult.skipped(index, item, :guard_rejected)
    else
      apply_handler(item, index, config.handler)
    end
  end

  defp apply_handler(item, index, handler) do
    case handler.(item) do
      {:ok, output} -> ItemResult.success(index, item, output)
      {:error, reason} -> ItemResult.failure(index, item, reason)
    end
  rescue
    exception -> ItemResult.failure(index, item, Exception.message(exception))
  end
end

defmodule BulkProcessor.Reporter do
  @moduledoc "Formats a bulk processing summary into a human-readable or machine-readable form."

  alias BulkProcessor.Summary

  @spec to_map(Summary.t()) :: map()
  def to_map(%Summary{} = summary) do
    %{
      total: summary.total,
      succeeded: summary.succeeded,
      failed: summary.failed,
      skipped: summary.skipped,
      duration_ms: summary.duration_ms,
      success_rate: success_rate(summary)
    }
  end

  @spec failed_items(Summary.t()) :: [BulkProcessor.ItemResult.t()]
  def failed_items(%Summary{results: results}) do
    Enum.filter(results, &(&1.status == :error))
  end

  @spec print_summary(Summary.t()) :: :ok
  def print_summary(%Summary{} = summary) do
    IO.puts("""
    Bulk operation complete:
      Total:     #{summary.total}
      Succeeded: #{summary.succeeded}
      Failed:    #{summary.failed}
      Skipped:   #{summary.skipped}
      Duration:  #{summary.duration_ms}ms
      Rate:      #{success_rate(summary)}%
    """)
  end

  defp success_rate(%Summary{total: 0}), do: 0.0
  defp success_rate(%Summary{total: total, succeeded: succeeded}) do
    Float.round(succeeded / total * 100, 1)
  end
end
```
