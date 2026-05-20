```elixir
defmodule PlatformMigration do
  @moduledoc """
  Orchestrates platform-level migration operations including database schema
  migrations, feature flag rollouts across user segments, and data backfills
  for legacy record transformation.
  """

  alias PlatformMigration.{
    SchemaMigration,
    FeatureRollout,
    DataBackfill,
    MigrationStore,
    SchemaRunner,
    FeatureFlagStore,
    BackfillWorker,
    MigrationLock,
    AlertManager,
    EngineeringNotifier
  }

  require Logger

  @doc """
  Run a platform migration operation.

  Accepts a `%SchemaMigration{}`, `%FeatureRollout{}`, or `%DataBackfill{}`
  and executes the corresponding migration workflow.

  ## Examples

      iex> PlatformMigration.run(%SchemaMigration{name: "add_index_users_email", direction: :up})
      {:ok, %{migration: "add_index_users_email", duration_ms: 342}}

  """
  def run(%SchemaMigration{
        name: migration_name,
        direction: direction,
        timeout_ms: timeout_ms
      })
      when direction in [:up, :down] do
    with :ok <- MigrationLock.acquire(migration_name),
         :ok <- validate_migration_state(migration_name, direction),
         started_at = System.monotonic_time(:millisecond),
         {:ok, result} <-
           SchemaRunner.execute(%{
             name: migration_name,
             direction: direction,
             timeout_ms: timeout_ms || 30_000
           }),
         duration_ms = System.monotonic_time(:millisecond) - started_at,
         :ok <- record_migration_result(migration_name, direction, result, duration_ms),
         :ok <- MigrationLock.release(migration_name),
         :ok <- EngineeringNotifier.send_migration_complete(migration_name, direction, duration_ms) do
      Logger.info("Schema migration #{migration_name} #{direction} completed in #{duration_ms}ms")
      {:ok, %{migration: migration_name, direction: direction, duration_ms: duration_ms}}
    else
      error ->
        MigrationLock.release(migration_name)
        AlertManager.notify_migration_failure(migration_name, direction, error)
        error
    end
  end

  # run feature flag rollout to a target user segment
  def run(%FeatureRollout{
        flag_key: flag_key,
        rollout_percentage: pct,
        target_segment: segment,
        rollout_strategy: strategy,
        enabled_by: engineer
      })
      when pct >= 0 and pct <= 100 do
    with {:ok, flag} <- FeatureFlagStore.find(flag_key),
         :ok <- validate_flag_inactive_or_partial(flag),
         :ok <- validate_rollout_increment(flag.current_percentage, pct),
         {:ok, updated_flag} <-
           FeatureFlagStore.update(flag_key, %{
             rollout_percentage: pct,
             target_segment: segment,
             strategy: strategy,
             enabled_by: engineer,
             updated_at: DateTime.utc_now()
           }),
         :ok <-
           MigrationStore.record(%{
             type: :feature_rollout,
             flag_key: flag_key,
             previous_pct: flag.current_percentage,
             new_pct: pct,
             segment: segment,
             rolled_out_by: engineer,
             at: DateTime.utc_now()
           }),
         :ok <- EngineeringNotifier.send_rollout_update(flag_key, pct, engineer) do
      Logger.info("Feature #{flag_key} rolled out to #{pct}% of #{segment} by #{engineer}")
      {:ok, %{flag_key: flag_key, rollout_percentage: pct, segment: segment}}
    end
  end

  # run data backfill for legacy records requiring transformation
  def run(%DataBackfill{
        backfill_id: backfill_id,
        source_table: source_table,
        transform_module: transform_mod,
        batch_size: batch_size,
        throttle_ms: throttle_ms
      })
      when batch_size > 0 and batch_size <= 1000 do
    with :ok <- MigrationLock.acquire("backfill_#{backfill_id}"),
         {:ok, total_rows} <- BackfillWorker.count_pending(source_table, backfill_id),
         :ok <-
           MigrationStore.record(%{
             type: :data_backfill,
             backfill_id: backfill_id,
             source_table: source_table,
             total_rows: total_rows,
             status: :running,
             started_at: DateTime.utc_now()
           }),
         {:ok, result} <-
           BackfillWorker.run_batched(%{
             backfill_id: backfill_id,
             source_table: source_table,
             transform: fn row -> apply(transform_mod, :transform, [row]) end,
             batch_size: batch_size,
             throttle_ms: throttle_ms
           }),
         :ok <-
           MigrationStore.update(backfill_id, %{
             status: :completed,
             processed: result.processed,
             failed: result.failed,
             completed_at: DateTime.utc_now()
           }),
         :ok <- MigrationLock.release("backfill_#{backfill_id}"),
         :ok <- EngineeringNotifier.send_backfill_complete(backfill_id, result) do
      Logger.info("Backfill #{backfill_id} completed: #{result.processed} processed, #{result.failed} failed")
      {:ok, result}
    else
      error ->
        MigrationLock.release("backfill_#{backfill_id}")
        AlertManager.notify_backfill_failure(backfill_id, error)
        error
    end
  end

  defp validate_migration_state(name, :up) do
    case MigrationStore.find(name) do
      {:ok, %{status: :completed}} -> {:error, :migration_already_run}
      {:ok, %{status: :running}} -> {:error, :migration_already_running}
      _ -> :ok
    end
  end

  defp validate_migration_state(name, :down) do
    case MigrationStore.find(name) do
      {:ok, %{status: :completed}} -> :ok
      _ -> {:error, :migration_not_yet_run}
    end
  end

  defp record_migration_result(name, direction, _result, duration_ms) do
    MigrationStore.record(%{
      name: name,
      direction: direction,
      status: :completed,
      duration_ms: duration_ms,
      run_at: DateTime.utc_now()
    })
  end

  defp validate_flag_inactive_or_partial(%{status: :inactive}), do: :ok
  defp validate_flag_inactive_or_partial(%{status: :partial_rollout}), do: :ok
  defp validate_flag_inactive_or_partial(%{status: :fully_enabled}), do: {:error, :flag_already_fully_enabled}
  defp validate_flag_inactive_or_partial(%{status: s}), do: {:error, {:unexpected_flag_status, s}}

  defp validate_rollout_increment(current_pct, new_pct) when new_pct > current_pct, do: :ok
  defp validate_rollout_increment(current_pct, new_pct) when new_pct <= current_pct, do: {:error, :rollout_must_increase}
end
```
