**File:** `example_good_1411.md`

```elixir
defmodule DataMigration.Step do
  @moduledoc "Represents a single versioned data migration step."

  @enforce_keys [:version, :description, :module]
  defstruct [:version, :description, :module]

  @type t :: %__MODULE__{
          version: pos_integer(),
          description: String.t(),
          module: module()
        }
end

defmodule DataMigration.Migration do
  @moduledoc "Behaviour for individual data migration implementations."

  @doc "Runs the forward data migration. Must be idempotent."
  @callback run(keyword()) :: :ok | {:error, term()}

  @doc "Validates preconditions before the migration runs."
  @callback validate(keyword()) :: :ok | {:error, String.t()}
end

defmodule DataMigration.Ledger do
  @moduledoc """
  Tracks which migration versions have been applied using an Ecto-backed
  table. Provides explicit read and write functions for the migration runner.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias MyApp.Repo

  @primary_key {:version, :integer, autogenerate: false}
  schema "data_migration_ledger" do
    field :description, :string
    field :applied_at, :utc_datetime_usec
  end

  @spec applied_versions() :: [pos_integer()]
  def applied_versions do
    __MODULE__
    |> select([l], l.version)
    |> order_by([l], asc: l.version)
    |> Repo.all()
  end

  @spec record(pos_integer(), String.t()) :: :ok | {:error, term()}
  def record(version, description) do
    attrs = %{version: version, description: description, applied_at: DateTime.utc_now()}

    %__MODULE__{}
    |> cast(attrs, [:version, :description, :applied_at])
    |> validate_required([:version, :description, :applied_at])
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end

defmodule DataMigration.Runner do
  @moduledoc """
  Runs pending data migrations in version order. Skips already-applied
  versions and validates preconditions before each step.
  """

  require Logger

  alias DataMigration.{Ledger, Step}

  @type run_result :: %{
          applied: [pos_integer()],
          skipped: [pos_integer()],
          failed: pos_integer() | nil,
          error: term() | nil
        }

  @spec run([Step.t()], keyword()) :: run_result()
  def run(steps, opts \\ []) when is_list(steps) do
    dry_run = Keyword.get(opts, :dry_run, false)
    applied_versions = Ledger.applied_versions()

    pending =
      steps
      |> Enum.sort_by(& &1.version)
      |> Enum.reject(fn s -> s.version in applied_versions end)

    skipped = Enum.map(steps, & &1.version) -- Enum.map(pending, & &1.version)

    Logger.info("Data migrations: #{length(pending)} pending, #{length(skipped)} already applied")

    if dry_run do
      Enum.each(pending, fn s ->
        Logger.info("Would apply migration v#{s.version}: #{s.description}")
      end)

      %{applied: [], skipped: skipped, failed: nil, error: nil}
    else
      execute_pending(pending, skipped, opts)
    end
  end

  defp execute_pending(pending, skipped, opts) do
    Enum.reduce_while(pending, %{applied: [], skipped: skipped, failed: nil, error: nil}, fn step, acc ->
      case run_step(step, opts) do
        :ok ->
          Logger.info("Migration v#{step.version} applied: #{step.description}")
          {:cont, %{acc | applied: acc.applied ++ [step.version]}}

        {:error, reason} ->
          Logger.error("Migration v#{step.version} failed: #{inspect(reason)}")
          {:halt, %{acc | failed: step.version, error: reason}}
      end
    end)
  end

  defp run_step(%Step{version: version, description: desc, module: mod}, opts) do
    with :ok <- mod.validate(opts),
         :ok <- mod.run(opts) do
      Ledger.record(version, desc)
    end
  end
end
```
