# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `DataImportPipeline.cast_row/2`, line where `String.to_atom/1` converts column name strings for each row |
| **Affected function(s)** | `DataImportPipeline.cast_row/2` |
| **Short explanation** | During bulk data import, each row from the incoming dataset is cast into a struct-like map using column names as atom keys. The column names come from an operator-supplied schema definition stored as JSON strings. For large imports with wide schemas, this call pattern can create many atoms—one per unique column name—and is repeated across all rows, compounding any naming variability. |

```elixir
defmodule MyApp.Imports.DataImportPipeline do
  @moduledoc """
  Orchestrates bulk data imports from external sources (CSV, JSON, API snapshots).
  Validates rows against an operator-defined column schema, casts types,
  and upserts records into the target table via batch inserts.
  """

  require Logger

  alias MyApp.Imports.{ImportJob, RowCaster, BatchInserter, ImportAudit}
  alias MyApp.Repo

  @batch_size 500
  @max_error_threshold 0.05

  @doc """
  Executes a data import job defined by an `ImportJob` struct.
  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec run(ImportJob.t()) :: {:ok, map()} | {:error, term()}
  def run(%ImportJob{id: job_id, schema: schema, rows: rows} = job) do
    Logger.info("Starting import job", job_id: job_id, row_count: length(rows))

    ImportAudit.start(job_id)

    {ok_count, error_count, batches} = process_rows(rows, schema)

    error_rate = if ok_count + error_count > 0, do: error_count / (ok_count + error_count), else: 0.0

    if error_rate > @max_error_threshold do
      Logger.error("Import aborted: error rate too high", job_id: job_id, error_rate: error_rate)
      ImportAudit.abort(job_id, :error_threshold_exceeded)
      {:error, :too_many_errors}
    else
      case BatchInserter.insert_all(job.target_table, batches) do
        {:ok, inserted} ->
          ImportAudit.complete(job_id, %{inserted: inserted, errors: error_count})
          Logger.info("Import job complete", job_id: job_id, inserted: inserted)
          {:ok, %{inserted: inserted, errors: error_count, error_rate: error_rate}}

        {:error, reason} = err ->
          Logger.error("Batch insert failed", job_id: job_id, reason: inspect(reason))
          ImportAudit.abort(job_id, reason)
          err
      end
    end
  end

  defp process_rows(rows, schema) do
    Enum.reduce(rows, {0, 0, []}, fn row, {ok, err, batches} ->
      case cast_row(row, schema) do
        {:ok, cast} ->
          batch = List.first(batches, [])
          if length(batch) >= @batch_size do
            {ok + 1, err, [[] | [batch | tl(batches || [[]])]]}
          else
            {ok + 1, err, [[cast | batch] | (tl(batches) || [])]}
          end

        {:error, _reason} ->
          {ok, err + 1, batches}
      end
    end)
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to every
  # column name from the operator-supplied schema definition on every call to
  # `cast_row/2`. Although the schema itself may be bounded, it originates as a
  # list of string-keyed JSON objects loaded from the database, meaning column names
  # are fundamentally dynamic strings. If operators define schemas with arbitrary
  # or evolving column names—or if the schema loader is extended to accept user
  # input—each new name string permanently occupies an atom table slot. The function
  # is also called once per row, so the smell is exercised at high frequency.
  defp cast_row(raw_row, schema) when is_map(raw_row) do
    Enum.reduce_while(schema, {:ok, %{}}, fn %{"column" => col, "type" => type}, {:ok, acc} ->
      raw_value = Map.get(raw_row, col)

      case RowCaster.cast(raw_value, type) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, String.to_atom(col), value)}}

        {:error, reason} ->
          {:halt, {:error, {:cast_error, col, reason}}}
      end
    end)
  end
  # VALIDATION: SMELL END

  defp cast_row(_, _), do: {:error, :invalid_row_format}
end
```
