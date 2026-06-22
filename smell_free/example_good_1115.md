```elixir
defmodule Scheduler.RecurringJob do
  @moduledoc """
  Represents a recurring job with a cron-style schedule expression,
  the callable module, and metadata for auditing and observability.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          schedule: String.t(),
          module: module(),
          enabled: boolean(),
          last_run_at: DateTime.t() | nil,
          next_run_at: DateTime.t() | nil
        }

  defstruct [:id, :name, :schedule, :module, :last_run_at, :next_run_at, enabled: true]
end

defmodule Scheduler.Clock do
  @moduledoc """
  A supervised GenServer that evaluates which recurring jobs are due
  on each tick and dispatches them to a worker pool for execution.
  Tick interval and job registry are supplied at startup.
  """

  use GenServer
  require Logger

  alias Scheduler.RecurringJob

  @default_tick_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    jobs = Keyword.fetch!(opts, :jobs)
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    schedule_tick(tick_ms)
    {:ok, %{jobs: jobs, tick_ms: tick_ms}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    state.jobs
    |> Enum.filter(&job_due?(&1, now))
    |> Enum.each(&dispatch_job/1)
    schedule_tick(state.tick_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp job_due?(%RecurringJob{enabled: false}, _now), do: false
  defp job_due?(%RecurringJob{next_run_at: nil}, _now), do: false
  defp job_due?(%RecurringJob{next_run_at: next}, now),
    do: DateTime.compare(now, next) in [:gt, :eq]

  defp dispatch_job(%RecurringJob{id: id, module: mod} = job) do
    Logger.info("Dispatching scheduled job", job_id: id, module: inspect(mod))
    case Workers.Supervisor.start_worker(%{id: id, type: :scheduled, payload: %{module: mod}}) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("Failed to start job", job_id: id, reason: inspect(reason))
    end
  end
end

defmodule Scheduler.Job do
  @moduledoc "Behaviour that all scheduled job modules must implement."

  @type result :: :ok | {:error, term()}

  @callback execute(map()) :: result()
end

defmodule Scheduler.Jobs.DatabaseVacuum do
  @moduledoc "Scheduled job that runs VACUUM ANALYZE on stale tables."

  @behaviour Scheduler.Job
  require Logger

  @impl Scheduler.Job
  def execute(%{tables: tables}) when is_list(tables) do
    Enum.each(tables, &vacuum_table/1)
  end

  def execute(_opts) do
    Logger.warning("DatabaseVacuum job called without a tables list; skipping.")
    :ok
  end

  defp vacuum_table(table) when is_binary(table) do
    Logger.info("Running VACUUM ANALYZE", table: table)
    Ecto.Adapters.SQL.query!(MyApp.Repo, "VACUUM ANALYZE #{table}", [])
    :ok
  end
end
```
