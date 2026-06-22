```elixir
defmodule Scheduler.CronRegistry do
  @moduledoc """
  A supervised GenServer that maintains a registry of named recurring jobs
  defined by cron expressions. Each job fires a configured MFA on schedule
  using monotonic timers for drift-resistant execution.
  """

  use GenServer

  alias Scheduler.CronParser

  @type job_spec :: %{
          name: atom(),
          schedule: String.t(),
          module: module(),
          function: atom(),
          args: [term()]
        }

  @type job_entry :: %{
          spec: job_spec(),
          next_run_at: DateTime.t(),
          last_run_at: DateTime.t() | nil,
          run_count: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(job_spec()) :: :ok | {:error, :already_registered}
  def register(spec) when is_map(spec) do
    GenServer.call(__MODULE__, {:register, spec})
  end

  @spec deregister(atom()) :: :ok
  def deregister(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:deregister, name})
  end

  @spec list_jobs() :: [job_entry()]
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @impl GenServer
  def init(_opts) do
    schedule_tick()
    {:ok, %{jobs: %{}}}
  end

  @impl GenServer
  def handle_call({:register, spec}, _from, state) do
    if Map.has_key?(state.jobs, spec.name) do
      {:reply, {:error, :already_registered}, state}
    else
      {:ok, next_run} = CronParser.next_occurrence(spec.schedule, DateTime.utc_now())
      entry = %{spec: spec, next_run_at: next_run, last_run_at: nil, run_count: 0}
      {:reply, :ok, put_in(state, [:jobs, spec.name], entry)}
    end
  end

  def handle_call(:list_jobs, _from, state) do
    {:reply, Map.values(state.jobs), state}
  end

  @impl GenServer
  def handle_cast({:deregister, name}, state) do
    {:noreply, update_in(state, [:jobs], &Map.delete(&1, name))}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    updated_jobs = Map.new(state.jobs, fn {name, entry} -> {name, maybe_run(entry, now)} end)
    schedule_tick()
    {:noreply, %{state | jobs: updated_jobs}}
  end

  @spec maybe_run(job_entry(), DateTime.t()) :: job_entry()
  defp maybe_run(entry, now) do
    if DateTime.compare(entry.next_run_at, now) != :gt do
      fire_job(entry.spec)
      {:ok, next_run} = CronParser.next_occurrence(entry.spec.schedule, now)
      %{entry | last_run_at: now, next_run_at: next_run, run_count: entry.run_count + 1}
    else
      entry
    end
  end

  @spec fire_job(job_spec()) :: :ok
  defp fire_job(%{module: mod, function: fun, args: args}) do
    Task.Supervisor.start_child(
      Scheduler.TaskSupervisor,
      fn -> apply(mod, fun, args) end
    )

    :ok
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)
end
```
