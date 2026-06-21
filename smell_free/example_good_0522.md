```elixir
defmodule MyApp.Admin.BackfillRunner do
  @moduledoc """
  Safely runs data backfill scripts on production tables by processing
  records in bounded, rate-limited batches. Each backfill is a named
  module implementing the `Backfill` behaviour; the runner tracks progress
  in the `backfill_runs` table so that interrupted backfills can be
  resumed from where they left off without reprocessing records.

  Start via the Mix release task:

      MyApp.Admin.BackfillRunner.run("MyApp.Backfills.AddSearchVector", dry_run: false)
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Admin.BackfillRun

  import Ecto.Query, warn: false

  @default_batch_size 200
  @default_sleep_ms 100

  @type opts :: [
          batch_size: pos_integer(),
          sleep_ms: non_neg_integer(),
          dry_run: boolean()
        ]

  @type run_summary :: %{
          module: String.t(),
          processed: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @doc """
  Executes the backfill identified by `module_name`. Pass `dry_run: true`
  to preview changes without committing them.
  """
  @spec run(String.t(), opts()) :: {:ok, run_summary()} | {:error, term()}
  def run(module_name, opts \\ []) when is_binary(module_name) do
    with {:ok, module} <- resolve_module(module_name) do
      start_ms = System.monotonic_time(:millisecond)
      batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
      sleep_ms = Keyword.get(opts, :sleep_ms, @default_sleep_ms)
      dry_run = Keyword.get(opts, :dry_run, true)
      cursor = load_cursor(module_name)

      Logger.info("backfill_started", module: module_name, dry_run: dry_run, cursor: cursor)

      {processed, skipped, errors, final_cursor} =
        execute_batches(module, cursor, batch_size, sleep_ms, dry_run)

      unless dry_run, do: save_cursor(module_name, final_cursor)

      duration_ms = System.monotonic_time(:millisecond) - start_ms

      summary = %{
        module: module_name,
        processed: processed,
        skipped: skipped,
        errors: errors,
        duration_ms: duration_ms
      }

      Logger.info("backfill_finished", Map.to_list(summary))
      {:ok, summary}
    end
  end

  @spec execute_batches(module(), term(), pos_integer(), non_neg_integer(), boolean()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), term()}
  defp execute_batches(module, cursor, batch_size, sleep_ms, dry_run) do
    Stream.iterate({0, 0, 0, cursor}, fn {p, s, e, cur} ->
      case module.next_batch(cur, batch_size) do
        [] -> :halt
        records ->
          {new_p, new_s, new_e} = process_records(module, records, dry_run)
          new_cursor = module.cursor_from(List.last(records))
          Process.sleep(sleep_ms)
          {p + new_p, s + new_s, e + new_e, new_cursor}
      end
    end)
    |> Enum.reduce_while({0, 0, 0, cursor}, fn
      :halt, acc -> {:halt, acc}
      state, _ -> {:cont, state}
    end)
  end

  @spec process_records(module(), [term()], boolean()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp process_records(module, records, dry_run) do
    Enum.reduce(records, {0, 0, 0}, fn record, {p, s, e} ->
      if dry_run do
        {p, s + 1, e}
      else
        case module.process(record) do
          :ok -> {p + 1, s, e}
          :skip -> {p, s + 1, e}
          {:error, _} -> {p, s, e + 1}
        end
      end
    end)
  end

  @spec resolve_module(String.t()) :: {:ok, module()} | {:error, :module_not_found}
  defp resolve_module(name) do
    module = Module.concat([name])

    if Code.ensure_loaded?(module), do: {:ok, module}, else: {:error, :module_not_found}
  end

  @spec load_cursor(String.t()) :: term()
  defp load_cursor(module_name) do
    case Repo.get_by(BackfillRun, module: module_name) do
      %BackfillRun{cursor: cursor} -> cursor
      nil -> nil
    end
  end

  @spec save_cursor(String.t(), term()) :: :ok
  defp save_cursor(module_name, cursor) do
    Repo.insert(
      %BackfillRun{module: module_name, cursor: cursor, updated_at: DateTime.utc_now()},
      on_conflict: {:replace, [:cursor, :updated_at]},
      conflict_target: :module
    )

    :ok
  end
end
```
