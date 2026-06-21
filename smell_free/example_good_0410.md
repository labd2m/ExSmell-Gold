```elixir
defmodule Platform.MigrationRunner do
  @moduledoc """
  Executes data migration scripts defined as modules implementing the
  `Platform.Migration` behaviour. Each migration is idempotent by design:
  the runner records completed migration IDs in a tracking table and
  skips any migration that has already run. Migrations execute in
  version-sorted order and each runs inside its own transaction.
  """

  require Logger

  alias MyApp.Repo
  alias Platform.MigrationRecord

  @doc "Runs all pending migrations from the given list of modules."
  @spec run([module()]) :: {:ok, %{ran: [String.t()], skipped: [String.t()]}}
  def run(migration_modules) when is_list(migration_modules) do
    completed = fetch_completed_ids()
    sorted = Enum.sort_by(migration_modules, & &1.version())

    {ran, skipped} =
      Enum.reduce(sorted, {[], []}, fn mod, {ran_acc, skipped_acc} ->
        id = migration_id(mod)

        if id in completed do
          {ran_acc, [id | skipped_acc]}
        else
          case execute_migration(mod, id) do
            :ok -> {[id | ran_acc], skipped_acc}
            {:error, reason} -> raise "Migration #{id} failed: #{inspect(reason)}"
          end
        end
      end)

    {:ok, %{ran: Enum.reverse(ran), skipped: Enum.reverse(skipped)}}
  end

  @doc "Returns the IDs of all previously completed migrations."
  @spec fetch_completed_ids() :: [String.t()]
  def fetch_completed_ids do
    import Ecto.Query
    from(m in MigrationRecord, select: m.migration_id) |> Repo.all()
  end

  defp execute_migration(mod, id) do
    Logger.info("[MigrationRunner] Running #{id}")

    Repo.transaction(fn ->
      mod.up()
      Repo.insert!(%MigrationRecord{migration_id: id, ran_at: DateTime.utc_now()})
    end)
    |> case do
      {:ok, _} ->
        Logger.info("[MigrationRunner] Completed #{id}")
        :ok
      {:error, reason} ->
        Logger.error("[MigrationRunner] Failed #{id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp migration_id(mod) do
    "#{mod.version()}_#{mod.name()}"
  end
end

defmodule Platform.Migration do
  @moduledoc "Behaviour contract for data migration modules."

  @doc "Unique integer version number, used to determine execution order."
  @callback version() :: pos_integer()

  @doc "Human-readable migration identifier, used in the tracking record."
  @callback name() :: String.t()

  @doc "Executes the migration. Must be idempotent when called repeatedly."
  @callback up() :: :ok
end
```
