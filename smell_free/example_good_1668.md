```elixir
defmodule Backfill.Plan do
  @moduledoc """
  Describes a backfill operation: which records to target and what function to apply.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          query_fn: (keyword() -> Ecto.Query.t()),
          transform_fn: (map() -> {:ok, map()} | :skip | {:error, term()}),
          batch_size: pos_integer(),
          concurrency: pos_integer()
        }

  defstruct [:name, :query_fn, :transform_fn, batch_size: 500, concurrency: 4]
end

defmodule Backfill.Runner do
  alias Backfill.Plan
  alias MyApp.Repo
  import Ecto.Query

  @moduledoc """
  Executes a `Backfill.Plan` by streaming batches of records from the
  database, applying the transformation function, and persisting changes.
  Supports configurable concurrency and provides live progress reporting.
  """

  @type run_result :: %{
          processed: non_neg_integer(),
          updated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec run(Plan.t(), keyword()) :: {:ok, run_result()}
  def run(%Plan{} = plan, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)

    total_count = count_records(plan)
    on_progress.(%{stage: :started, total: total_count})

    result = stream_batches(plan, on_progress)

    on_progress.(%{stage: :completed, result: result})
    {:ok, result}
  end

  defp count_records(%Plan{query_fn: query_fn}) do
    query_fn.([])
    |> select(count())
    |> Repo.one()
  end

  defp stream_batches(%Plan{} = plan, on_progress) do
    plan.query_fn.([])
    |> order_by([r], asc: r.id)
    |> Repo.stream(max_rows: plan.batch_size)
    |> Stream.chunk_every(plan.batch_size)
    |> Task.async_stream(
      fn batch -> process_batch(batch, plan.transform_fn) end,
      max_concurrency: plan.concurrency,
      timeout: 60_000
    )
    |> Enum.reduce(%{processed: 0, updated: 0, skipped: 0, errors: 0}, fn
      {:ok, batch_stats}, acc ->
        updated_acc = merge_stats(acc, batch_stats)
        on_progress.(%{stage: :batch_done, cumulative: updated_acc})
        updated_acc

      {:exit, _reason}, acc ->
        %{acc | errors: acc.errors + 1}
    end)
  end

  defp process_batch(records, transform_fn) do
    Enum.reduce(records, %{processed: 0, updated: 0, skipped: 0, errors: 0}, fn record, stats ->
      result = apply_transform(record, transform_fn)
      update_stats(stats, result)
    end)
  end

  defp apply_transform(record, transform_fn) do
    case transform_fn.(record) do
      {:ok, updated_attrs} ->
        case Repo.update(Ecto.Changeset.change(record, updated_attrs)) do
          {:ok, _} -> :updated
          {:error, _} -> :error
        end

      :skip ->
        :skipped

      {:error, _} ->
        :error
    end
  end

  defp update_stats(stats, :updated) do
    %{stats | processed: stats.processed + 1, updated: stats.updated + 1}
  end

  defp update_stats(stats, :skipped) do
    %{stats | processed: stats.processed + 1, skipped: stats.skipped + 1}
  end

  defp update_stats(stats, :error) do
    %{stats | processed: stats.processed + 1, errors: stats.errors + 1}
  end

  defp merge_stats(acc, batch) do
    %{
      processed: acc.processed + batch.processed,
      updated: acc.updated + batch.updated,
      skipped: acc.skipped + batch.skipped,
      errors: acc.errors + batch.errors
    }
  end
end
```
