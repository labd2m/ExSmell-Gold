```elixir
defmodule Repo.BulkUpsert do
  @moduledoc """
  Performs chunked bulk upserts using Ecto's `insert_all/3` with
  `on_conflict` resolution.

  Large datasets are split into configurable chunks to avoid exceeding
  database bind-parameter limits. Each chunk executes in a single
  statement; all chunks run inside one transaction so partial failures
  roll back completely rather than leaving the table in an inconsistent
  intermediate state.
  """

  alias Ecto.Multi

  @default_chunk_size 500

  @type upsert_opts :: [
          conflict_target: [atom()] | {:constraint, atom()},
          replace_fields: [atom()],
          chunk_size: pos_integer(),
          timestamps: boolean()
        ]

  @type upsert_result :: {:ok, %{inserted: non_neg_integer()}} | {:error, term()}

  @spec upsert_all(module(), atom(), [map()], upsert_opts()) :: upsert_result()
  def upsert_all(repo, schema, rows, opts \\ [])
      when is_atom(repo) and is_atom(schema) and is_list(rows) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    conflict_target = Keyword.get(opts, :conflict_target, [])
    replace_fields = Keyword.get(opts, :replace_fields, [])
    add_timestamps = Keyword.get(opts, :timestamps, true)

    prepared_rows = if add_timestamps, do: Enum.map(rows, &stamp/1), else: rows
    chunks = Enum.chunk_every(prepared_rows, chunk_size)

    multi =
      chunks
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {chunk, idx}, multi ->
        Multi.insert_all(multi, {:chunk, idx}, schema, chunk,
          on_conflict: resolve_conflict(replace_fields),
          conflict_target: conflict_target,
          returning: false
        )
      end)

    case repo.transaction(multi) do
      {:ok, results} ->
        total = results |> Map.values() |> Enum.sum_by(fn {n, _} -> n end)
        {:ok, %{inserted: total}}

      {:error, _failed_op, reason, _changes_so_far} ->
        {:error, reason}
    end
  end

  @spec upsert_one(module(), Ecto.Schema.t(), map(), upsert_opts()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def upsert_one(repo, changeset, opts \\ []) do
    conflict_target = Keyword.get(opts, :conflict_target, [])
    replace_fields = Keyword.get(opts, :replace_fields, [])

    repo.insert(changeset,
      on_conflict: resolve_conflict(replace_fields),
      conflict_target: conflict_target
    )
  end

  defp resolve_conflict([]), do: :nothing

  defp resolve_conflict(replace_fields) when is_list(replace_fields) do
    {:replace, replace_fields}
  end

  defp stamp(%{} = row) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row
    |> Map.put_new(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end
end
```
