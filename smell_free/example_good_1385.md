**File:** `example_good_1385.md`

```elixir
defmodule Scheduler.JobRunner do
  @moduledoc """
  A GenServer that periodically executes a configured set of background jobs.
  Each job is an independent module implementing the `Scheduler.Job` behaviour.
  """

  use GenServer

  require Logger

  alias Scheduler.Job

  @type job_spec :: %{
          module: module(),
          interval_ms: pos_integer(),
          last_run_at: integer() | nil
        }

  @type state :: %{
          jobs: [job_spec()]
          }

  @tick_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register(GenServer.server(), module(), pos_integer()) :: :ok
  def register(server, module, interval_ms) do
    GenServer.call(server, {:register, module, interval_ms})
  end

  @spec list_jobs(GenServer.server()) :: [job_spec()]
  def list_jobs(server) do
    GenServer.call(server, :list_jobs)
  end

  @impl GenServer
  def init(opts) do
    initial_jobs =
      opts
      |> Keyword.get(:jobs, [])
      |> Enum.map(fn {mod, interval} ->
        %{module: mod, interval_ms: interval, last_run_at: nil}
      end)

    schedule_tick()
    {:ok, %{jobs: initial_jobs}}
  end

  @impl GenServer
  def handle_call({:register, module, interval_ms}, _from, %{jobs: jobs} = state) do
    spec = %{module: module, interval_ms: interval_ms, last_run_at: nil}
    {:reply, :ok, %{state | jobs: [spec | jobs]}}
  end

  def handle_call(:list_jobs, _from, state) do
    {:reply, state.jobs, state}
  end

  @impl GenServer
  def handle_info(:tick, %{jobs: jobs} = state) do
    now = System.monotonic_time(:millisecond)
    updated_jobs = Enum.map(jobs, &maybe_run_job(&1, now))
    schedule_tick()
    {:noreply, %{state | jobs: updated_jobs}}
  end

  defp maybe_run_job(%{last_run_at: nil} = spec, now) do
    run_job(spec, now)
  end

  defp maybe_run_job(%{last_run_at: last, interval_ms: interval} = spec, now)
       when now - last >= interval do
    run_job(spec, now)
  end

  defp maybe_run_job(spec, _now), do: spec

  defp run_job(%{module: module} = spec, now) do
    Task.start(fn ->
      case Job.execute(module) do
        :ok ->
          Logger.debug("Job #{inspect(module)} completed successfully")

        {:error, reason} ->
          Logger.warning("Job #{inspect(module)} failed: #{inspect(reason)}")
      end
    end)

    %{spec | last_run_at: now}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end
end

defmodule Scheduler.Job do
  @moduledoc """
  Behaviour contract for background jobs managed by `Scheduler.JobRunner`.
  """

  @doc "Executes the job. Returns `:ok` on success or `{:error, reason}` on failure."
  @callback run() :: :ok | {:error, term()}

  @spec execute(module()) :: :ok | {:error, term()}
  def execute(module) do
    module.run()
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end
end

defmodule Scheduler.Jobs.ExpireTokens do
  @moduledoc "Background job that removes expired authentication tokens from the database."

  @behaviour Scheduler.Job

  alias Auth.TokenStore

  @impl Scheduler.Job
  def run do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    case TokenStore.delete_expired_before(cutoff) do
      {:ok, count} ->
        if count > 0, do: require(Logger) && Logger.info("Expired #{count} tokens")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```
