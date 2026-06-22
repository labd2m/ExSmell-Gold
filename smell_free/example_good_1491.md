```elixir
defmodule Scheduler.JobRunner do
  @moduledoc """
  Periodic job scheduler backed by a GenServer tick loop.
  Registered jobs are invoked on their configured interval without external cron dependencies.
  """

  use GenServer

  @type job_fn :: (() -> :ok | {:error, String.t()})
  @type job :: %{name: String.t(), interval_ms: pos_integer(), last_run: integer() | nil, fun: job_fn()}
  @type state :: %{jobs: [job()]}

  @tick_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{jobs: []}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register_job(String.t(), pos_integer(), job_fn()) :: :ok
  def register_job(name, interval_ms, fun)
      when is_binary(name) and is_integer(interval_ms) and interval_ms > 0 and is_function(fun, 0) do
    GenServer.cast(__MODULE__, {:register, name, interval_ms, fun})
  end

  @spec remove_job(String.t()) :: :ok
  def remove_job(name) when is_binary(name) do
    GenServer.cast(__MODULE__, {:remove, name})
  end

  @spec list_jobs() :: [%{name: String.t(), interval_ms: pos_integer()}]
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @impl GenServer
  def init(state) do
    schedule_tick()
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:register, name, interval_ms, fun}, state) do
    job = %{name: name, interval_ms: interval_ms, last_run: nil, fun: fun}
    updated_jobs = Enum.reject(state.jobs, &(&1.name == name)) ++ [job]
    {:noreply, %{state | jobs: updated_jobs}}
  end

  def handle_cast({:remove, name}, state) do
    {:noreply, %{state | jobs: Enum.reject(state.jobs, &(&1.name == name))}}
  end

  @impl GenServer
  def handle_call(:list_jobs, _from, state) do
    summary = Enum.map(state.jobs, &%{name: &1.name, interval_ms: &1.interval_ms})
    {:reply, summary, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    updated_jobs = Enum.map(state.jobs, &maybe_run_job(&1, now))
    schedule_tick()
    {:noreply, %{state | jobs: updated_jobs}}
  end

  @spec maybe_run_job(job(), integer()) :: job()
  defp maybe_run_job(%{last_run: nil} = job, now) do
    execute_job(job, now)
  end

  defp maybe_run_job(job, now) do
    if now - job.last_run >= job.interval_ms do
      execute_job(job, now)
    else
      job
    end
  end

  @spec execute_job(job(), integer()) :: job()
  defp execute_job(job, now) do
    Task.start(job.fun)
    %{job | last_run: now}
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)
end
```
