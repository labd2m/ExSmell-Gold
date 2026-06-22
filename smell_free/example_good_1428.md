```elixir
defmodule Sync.BulkUpsert do
  @moduledoc """
  Performs efficient bulk upsert operations against Ecto schemas using
  `Repo.insert_all/3` with configurable conflict targets and update
  column sets. Handles batching to stay within database parameter limits.
  """

  alias Ecto.Repo

  @max_batch_size 500

  @type upsert_opts :: [
          conflict_target: [atom()],
          replace_fields: [atom()],
          batch_size: pos_integer(),
          returning: boolean()
        ]

  @type upsert_result :: %{
          inserted: non_neg_integer(),
          batches: non_neg_integer()
        }

  @spec upsert_all(module(), [map()], Repo.t(), upsert_opts()) ::
          {:ok, upsert_result()} | {:error, atom()}
  def upsert_all(schema, records, repo, opts \\ [])
      when is_atom(schema) and is_list(records) do
    batch_size = Keyword.get(opts, :batch_size, @max_batch_size)
    conflict_target = Keyword.fetch!(opts, :conflict_target)
    replace_fields = Keyword.get(opts, :replace_fields, [])

    stamped = Enum.map(records, &stamp_timestamps/1)

    batches = Enum.chunk_every(stamped, batch_size)

    result =
      Enum.reduce_while(batches, %{inserted: 0, batches: 0}, fn batch, acc ->
        on_conflict = build_on_conflict(replace_fields)

        case repo.insert_all(schema, batch,
               on_conflict: on_conflict,
               conflict_target: conflict_target,
               returning: Keyword.get(opts, :returning, false)
             ) do
          {count, _} ->
            {:cont, %{inserted: acc.inserted + count, batches: acc.batches + 1}}
        end
      end)

    {:ok, result}
  rescue
    e in Ecto.QueryError -> {:error, {:query_error, Exception.message(e)}}
    _ -> {:error, :unexpected_error}
  end

  @spec build_on_conflict([atom()]) :: {:replace, [atom()]} | :nothing
  defp build_on_conflict([]), do: :nothing

  defp build_on_conflict(fields) do
    {:replace, fields}
  end

  @spec stamp_timestamps(map()) :: map()
  defp stamp_timestamps(record) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    record
    |> Map.put_new(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  @spec dedup_by(module(), [map()], Repo.t(), atom()) ::
          {:ok, %{new: non_neg_integer(), existing: non_neg_integer()}} | {:error, atom()}
  def dedup_by(schema, records, repo, unique_key) when is_atom(unique_key) do
    existing_keys =
      repo.all(
        from(r in schema, select: field(r, ^unique_key))
      )
      |> MapSet.new()

    {new_records, existing_records} =
      Enum.split_with(records, fn r ->
        not MapSet.member?(existing_keys, Map.fetch!(r, unique_key))
      end)

    case upsert_all(schema, new_records, repo, conflict_target: [unique_key]) do
      {:ok, _} ->
        {:ok, %{new: length(new_records), existing: length(existing_records)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```
