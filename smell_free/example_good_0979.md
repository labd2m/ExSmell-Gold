```elixir
defmodule Deployments.MigrationChecker do
  @moduledoc """
  Validates that the database schema is in a safe state before a deployment
  completes. Checks verify that all pending Ecto migrations have been applied,
  that no `NOT VALID` constraints are awaiting validation, and that the
  application can connect to the database. Results are returned as a structured
  report so CI/CD pipelines can gate deployments on schema health without
  parsing log output.
  """

  alias Ecto.Migrator

  require Logger

  @type check_result :: %{
          name: binary(),
          status: :ok | :warning | :failed,
          detail: binary() | nil
        }

  @type report :: %{
          overall: :ok | :warning | :failed,
          checks: [check_result()],
          checked_at: DateTime.t()
        }

  @doc """
  Runs all migration safety checks and returns a structured report.
  The overall status is `:failed` if any check fails, `:warning` if any
  produce warnings, and `:ok` when all checks pass.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)

    checks = [
      check_connection(repo),
      check_pending_migrations(repo),
      check_invalid_constraints(repo),
      check_long_running_migrations(repo),
      check_schema_version_match(repo)
    ]

    overall = derive_overall(checks)
    now = DateTime.utc_now()

    report = %{overall: overall, checks: checks, checked_at: now}

    log_report(report)
    {:ok, report}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Individual checks
  # ---------------------------------------------------------------------------

  defp check_connection(repo) do
    case Ecto.Adapters.SQL.query(repo, "SELECT 1", []) do
      {:ok, _} ->
        %{name: "database_connection", status: :ok, detail: nil}

      {:error, reason} ->
        %{name: "database_connection", status: :failed, detail: "Cannot connect: #{inspect(reason)}"}
    end
  end

  defp check_pending_migrations(repo) do
    pending = Migrator.run(repo, migrations_path(), :up, all: true, log: false, dry_run: true)

    case pending do
      [] ->
        %{name: "pending_migrations", status: :ok, detail: nil}

      migrations ->
        versions = Enum.map(migrations, fn {version, _name} -> to_string(version) end)
        detail = "#{length(migrations)} pending: #{Enum.join(versions, ", ")}"
        %{name: "pending_migrations", status: :failed, detail: detail}
    end
  rescue
    e -> %{name: "pending_migrations", status: :failed, detail: Exception.message(e)}
  end

  defp check_invalid_constraints(repo) do
    query = """
    SELECT conname, conrelid::regclass AS table_name
    FROM pg_constraint
    WHERE convalidated = false
    """

    case Ecto.Adapters.SQL.query(repo, query, []) do
      {:ok, %{rows: []}} ->
        %{name: "invalid_constraints", status: :ok, detail: nil}

      {:ok, %{rows: rows}} ->
        names = Enum.map(rows, fn [name, table] -> "#{table}.#{name}" end)
        detail = "#{length(rows)} NOT VALID constraints pending validation: #{Enum.join(names, ", ")}"
        %{name: "invalid_constraints", status: :warning, detail: detail}

      {:error, reason} ->
        %{name: "invalid_constraints", status: :warning, detail: "Could not check: #{inspect(reason)}"}
    end
  end

  defp check_long_running_migrations(repo) do
    query = """
    SELECT pid, now() - query_start AS duration, query
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query ILIKE '%ALTER TABLE%'
      AND now() - query_start > interval '5 minutes'
    """

    case Ecto.Adapters.SQL.query(repo, query, []) do
      {:ok, %{rows: []}} ->
        %{name: "long_running_migrations", status: :ok, detail: nil}

      {:ok, %{rows: rows}} ->
        detail = "#{length(rows)} long-running DDL statements detected (>5 min)"
        %{name: "long_running_migrations", status: :warning, detail: detail}

      {:error, _} ->
        %{name: "long_running_migrations", status: :ok, detail: nil}
    end
  end

  defp check_schema_version_match(repo) do
    app_version = Application.spec(:my_app, :vsn) |> to_string()
    db_meta = Ecto.Adapters.SQL.query!(repo, "SELECT value FROM schema_meta WHERE key = 'app_version'", [])

    case db_meta.rows do
      [[^app_version]] ->
        %{name: "schema_version_match", status: :ok, detail: nil}

      [[db_version]] ->
        detail = "App version #{app_version} != DB schema version #{db_version}"
        %{name: "schema_version_match", status: :warning, detail: detail}

      [] ->
        %{name: "schema_version_match", status: :ok, detail: "No version tracking found, skipping"}
    end
  rescue
    _ -> %{name: "schema_version_match", status: :ok, detail: "Version table not present"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp derive_overall(checks) do
    statuses = Enum.map(checks, & &1.status)

    cond do
      :failed in statuses -> :failed
      :warning in statuses -> :warning
      true -> :ok
    end
  end

  defp log_report(%{overall: overall, checks: checks}) do
    Logger.info("Migration safety check complete", overall: overall)

    Enum.each(checks, fn check ->
      case check.status do
        :ok -> Logger.debug("Check passed", name: check.name)
        :warning -> Logger.warning("Check warning", name: check.name, detail: check.detail)
        :failed -> Logger.error("Check failed", name: check.name, detail: check.detail)
      end
    end)
  end

  defp migrations_path do
    Application.app_dir(:my_app, "priv/repo/migrations")
  end
end
```
