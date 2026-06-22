```elixir
defmodule Sync.BatchUpsert do
  @moduledoc """
  Provides high-throughput batch upsert operations for syncing external data
  sources into the local database. Records are inserted in configurable chunk
  sizes using `Repo.insert_all/3` with `:on_conflict` semantics, minimising
  round-trips. Each chunk is executed in its own transaction so a single
  malformed chunk can be retried or skipped without rolling back the entire
  batch. A structured result summary tracks per-chunk outcomes.
  """

  alias Ecto.Multi
  alias MyApp.Repo

  require Logger

  @type upsert_opts :: [
          chunk_size: pos_integer(),
          conflict_target: [atom()] | {:unsafe_fragment, binary()},
          on_conflict: atom() | keyword(),
          schema: module()
        ]

  @type batch_result :: %{
          total: non_neg_integer(),
          inserted: non_neg_integer(),
          chunks_succeeded: non_neg_integer(),
          chunks_failed: non_neg_integer(),
          errors: [%{chunk: non_neg_integer(), reason: term()}]
        }

  @default_chunk_size 500

  @doc """
  Upserts `records` into `schema` in chunks. Each record must be a plain map
  matching the schema's fields. Timestamps (`inserted_at`, `updated_at`) are
  injected automatically. Returns a `batch_result` map.
  """
  @spec upsert_all([map()], upsert_opts()) :: batch_result()
  def upsert_all(records, opts) when is_list(records) do
    schema = Keyword.fetch!(opts, :schema)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    conflict_target = Keyword.fetch!(opts, :conflict_target)
    on_conflict = Keyword.get(opts, :on_conflict, :replace_all)

    now = DateTime.utc_now()
    stamped = Enum.map(records, &stamp_record(&1, now))

    Logger.info("Starting batch upsert",
      schema: inspect(schema),
      total_records: length(records),
      chunk_size: chunk_size
    )

    stamped
    |> Enum.chunk_every(chunk_size)
    |> Enum.with_index(1)
    |> Enum.reduce(empty_result(length(records)), fn {chunk, chunk_idx}, acc ->
      case upsert_chunk(chunk, schema, conflict_target, on_conflict) do
        {:ok, count} ->
          %{acc | inserted: acc.inserted + count, chunks_succeeded: acc.chunks_succeeded + 1}

        {:error, reason} ->
          Logger.warning("Batch upsert chunk failed",
            chunk: chunk_idx,
            size: length(chunk),
            reason: inspect(reason)
          )

          entry = %{chunk: chunk_idx, reason: reason}
          %{acc | chunks_failed: acc.chunks_failed + 1, errors: [entry | acc.errors]}
      end
    end)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  @doc """
  Upserts records and verifies the expected count was written.
  Returns `{:ok, count}` or `{:error, {:count_mismatch, expected, actual}}`.
  """
  @spec upsert_exact([map()], non_neg_integer(), upsert_opts()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert_exact(records, expected_count, opts) do
    result = upsert_all(records, opts)

    cond do
      result.chunks_failed > 0 ->
        {:error, {:chunk_failures, result.errors}}

      result.inserted != expected_count ->
        {:error, {:count_mismatch, expected_count, result.inserted}}

      true ->
        {:ok, result.inserted}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp upsert_chunk(chunk, schema, conflict_target, on_conflict) do
    Repo.transaction(fn ->
      case Repo.insert_all(schema, chunk,
             conflict_target: conflict_target,
             on_conflict: on_conflict,
             returning: false
           ) do
        {count, _} -> count
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp stamp_record(record, now) do
    record
    |> Map.put_new(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  defp empty_result(total) do
    %{
      total: total,
      inserted: 0,
      chunks_succeeded: 0,
      chunks_failed: 0,
      errors: []
    }
  end
end
```
