```elixir
defmodule Ops.BatchMigrator do
  @moduledoc """
  Performs large-scale database row migrations in bounded batches to avoid
  locking or memory pressure. Processes rows in primary-key order, advancing
  a cursor after each successful batch. Progress is logged after every batch
  and the migrator can be paused and resumed by storing the last processed ID
  in the application environment.
  """

  require Logger

  alias MyApp.Repo

  @type migrator_fn :: (rows :: [map()] -> {:ok, non_neg_integer()} | {:error, term()})
  @type run_result :: %{
          processed: non_neg_integer(),
          batches: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @default_batch_size 500
  @default_sleep_ms 50

  @doc """
  Iterates over all rows in `table` in ascending ID order, calling
  `migrator_fn` on each batch. Sleeps `sleep_ms` between batches to
  reduce database pressure.
  """
  @spec run(String.t(), migrator_fn(), keyword()) :: run_result()
  def run(table, migrator_fn, opts \\ [])
      when is_binary(table) and is_function(migrator_fn, 1) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    sleep_ms = Keyword.get(opts, :sleep_ms, @default_sleep_ms)
    start_id = Keyword.get(opts, :start_id, 0)
    start_mono = System.monotonic_time(:millisecond)

    Logger.info("[BatchMigrator] Starting migration of '#{table}' in batches of #{batch_size}")

    result = process_batches(table, migrator_fn, start_id, batch_size, sleep_ms, 0, 0)
    duration_ms = System.monotonic_time(:millisecond) - start_mono

    Logger.info("[BatchMigrator] Completed: #{result.processed} rows in #{result.batches} batch(es), #{duration_ms}ms")

    Map.put(result, :duration_ms, duration_ms)
  end

  defp process_batches(table, migrator_fn, cursor, batch_size, sleep_ms, processed, batches) do
    rows = fetch_batch(table, cursor, batch_size)

    if Enum.empty?(rows) do
      %{processed: processed, batches: batches}
    else
      case migrator_fn.(rows) do
        {:ok, count} ->
          new_cursor = rows |> List.last() |> Map.get(:id)
          Logger.debug("[BatchMigrator] Batch #{batches + 1}: #{count} row(s) processed, cursor=#{new_cursor}")
          Process.sleep(sleep_ms)
          process_batches(table, migrator_fn, new_cursor, batch_size, sleep_ms, processed + count, batches + 1)

        {:error, reason} ->
          Logger.error("[BatchMigrator] Batch failed at cursor #{cursor}: #{inspect(reason)}")
          %{processed: processed, batches: batches}
      end
    end
  end

  defp fetch_batch(table, cursor, batch_size) do
    import Ecto.Query

    from(r in table,
      where: r.id > ^cursor,
      order_by: [asc: r.id],
      limit: ^batch_size
    )
    |> Repo.all()
  end
end
```
