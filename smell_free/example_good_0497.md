```elixir
defmodule Platform.BulkUpsert do
  @moduledoc """
  Efficient bulk insert and upsert helpers built on `Repo.insert_all/3`.

  Batches large record sets to stay within database parameter limits,
  reports per-batch results, and supports configurable conflict resolution
  strategies for idempotent import pipelines.
  """

  alias Platform.Repo

  @type record :: map()
  @type conflict_strategy :: :nothing | {:replace, [atom()]} | :replace_all
  @type batch_result :: %{inserted: non_neg_integer(), failed: non_neg_integer()}
  @type upsert_opts :: [
          batch_size: pos_integer(),
          conflict_target: [atom()] | atom(),
          on_conflict: conflict_strategy(),
          timestamps: boolean()
        ]

  @default_batch_size 500

  @doc """
  Inserts `records` into `schema_or_source` in batches.

  Returns a summary of total inserted and failed rows across all batches.
  Each batch is committed independently; a failure in one batch does not
  roll back prior batches.
  """
  @spec insert_all(module() | String.t(), [record()], upsert_opts()) :: batch_result()
  def insert_all(schema_or_source, records, opts \\ []) when is_list(records) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    timestamps? = Keyword.get(opts, :timestamps, true)

    records
    |> maybe_add_timestamps(timestamps?)
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce(%{inserted: 0, failed: 0}, fn batch, acc ->
      case insert_batch(schema_or_source, batch, opts) do
        {:ok, count} -> Map.update!(acc, :inserted, &(&1 + count))
        {:error, _} -> Map.update!(acc, :failed, &(&1 + length(batch)))
      end
    end)
  end

  @doc """
  Like `insert_all/3` but raises on any batch failure instead of
  collecting errors into the summary.
  """
  @spec insert_all!(module() | String.t(), [record()], upsert_opts()) :: non_neg_integer()
  def insert_all!(schema_or_source, records, opts \\ []) do
    %{inserted: count, failed: 0} = insert_all(schema_or_source, records, opts)
    count
  rescue
    MatchError -> raise "Bulk insert failed; check logs for batch-level errors"
  end

  @doc """
  Upserts `records` using `conflict_target` to identify conflicts.
  Replaces `replace_fields` on conflict.
  """
  @spec upsert_all(module(), [record()], [atom()], [atom()], upsert_opts()) :: batch_result()
  def upsert_all(schema, records, conflict_target, replace_fields, opts \\ []) do
    upsert_opts =
      opts
      |> Keyword.put(:conflict_target, conflict_target)
      |> Keyword.put(:on_conflict, {:replace, replace_fields ++ [:updated_at]})

    insert_all(schema, records, upsert_opts)
  end

  defp insert_batch(schema_or_source, batch, opts) do
    conflict_target = Keyword.get(opts, :conflict_target, [])
    on_conflict = Keyword.get(opts, :on_conflict, :nothing)

    repo_opts =
      [on_conflict: on_conflict]
      |> maybe_add_conflict_target(conflict_target)

    try do
      {count, _} = Repo.insert_all(schema_or_source, batch, repo_opts)
      {:ok, count}
    rescue
      error -> {:error, error}
    end
  end

  defp maybe_add_conflict_target(opts, []), do: opts
  defp maybe_add_conflict_target(opts, target), do: Keyword.put(opts, :conflict_target, target)

  defp maybe_add_timestamps(records, false), do: records

  defp maybe_add_timestamps(records, true) do
    now = DateTime.utc_now()
    Enum.map(records, fn record ->
      record
      |> Map.put_new(:inserted_at, now)
      |> Map.put(:updated_at, now)
    end)
  end
end
```
