```elixir
defmodule Scheduling.Jobs.RecurringRunner do
  @moduledoc """
  Manages and executes recurring background jobs defined by cron-style schedules.
  Each job is registered with a name, schedule interval, and execution function.
  Jobs are run in isolated supervised tasks to prevent failures from affecting others.
  """

  use GenServer

  @tick_interval_ms 60_000

  @type job :: %{
          name: String.t(),
          interval_seconds: pos_integer(),
          last_run_at: DateTime.t() | nil,
          run: (() -> :ok | {:error, term()})
        }
  @type state :: %{jobs: %{String.t() => job()}, task_supervisor: atom()}

  @doc """
  Starts the RecurringRunner linked to the calling process.

  ## Options
    - `:task_supervisor` - name of the `Task.Supervisor` for isolated job execution (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a recurring job. Returns `{:error, :already_registered}` if the name exists.
  """
  @spec register(String.t(), pos_integer(), (() -> :ok | {:error, term()})) ::
          :ok | {:error, :already_registered | String.t()}
  def register(name, interval_seconds, fun)
      when is_binary(name) and is_integer(interval_seconds) and interval_seconds > 0 and
             is_function(fun, 0) do
    GenServer.call(__MODULE__, {:register, name, interval_seconds, fun})
  end

  def register(_name, _interval, _fun), do: {:error, "invalid job parameters"}

  @doc """
  Removes a registered job by name.
  """
  @spec deregister(String.t()) :: :ok
  def deregister(name) when is_binary(name) do
    GenServer.cast(__MODULE__, {:deregister, name})
  end

  @doc """
  Triggers an immediate out-of-schedule run for `name`.
  Returns `{:error, :not_found}` if the job does not exist.
  """
  @spec run_now(String.t()) :: :ok | {:error, :not_found}
  def run_now(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:run_now, name})
  end

  @impl GenServer
  def init(opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    schedule_tick()
    {:ok, %{jobs: %{}, task_supervisor: task_supervisor}}
  end

  @impl GenServer
  def handle_call({:register, name, interval_seconds, fun}, _from, state) do
    if Map.has_key?(state.jobs, name) do
      {:reply, {:error, :already_registered}, state}
    else
      job = %{name: name, interval_seconds: interval_seconds, last_run_at: nil, run: fun}
      {:reply, :ok, %{state | jobs: Map.put(state.jobs, name, job)}}
    end
  end

  @impl GenServer
  def handle_call({:run_now, name}, _from, state) do
    case Map.fetch(state.jobs, name) do
      {:ok, job} ->
        dispatch_job(job, state.task_supervisor)
        updated_job = %{job | last_run_at: DateTime.utc_now()}
        {:reply, :ok, %{state | jobs: Map.put(state.jobs, name, updated_job)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_cast({:deregister, name}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, name)}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    updated_jobs =
      state.jobs
      |> Enum.map(fn {name, job} -> {name, maybe_run_job(job, now, state.task_supervisor)} end)
      |> Map.new()

    schedule_tick()
    {:noreply, %{state | jobs: updated_jobs}}
  end

  defp maybe_run_job(job, now, supervisor) do
    if due?(job, now) do
      dispatch_job(job, supervisor)
      %{job | last_run_at: now}
    else
      job
    end
  end

  defp due?(%{last_run_at: nil}, _now), do: true

  defp due?(%{last_run_at: last, interval_seconds: interval}, now) do
    DateTime.diff(now, last, :second) >= interval
  end

  defp dispatch_job(job, supervisor) do
    Task.Supervisor.start_child(supervisor, fn ->
      case job.run.() do
        :ok ->
          :telemetry.execute([:scheduling, :job, :success], %{}, %{job_name: job.name})

        {:error, reason} ->
          :telemetry.execute([:scheduling, :job, :failure], %{}, %{
            job_name: job.name,
            reason: reason
          })
      end
    end)
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)
end
```
