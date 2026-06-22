**File:** `example_good_1073.md`

```elixir
defmodule Scheduler.JobRunner do
  @moduledoc """
  Stateful job scheduler that executes registered recurring tasks on
  configurable cron-like intervals. Jobs are tracked in process state
  and executed asynchronously to avoid blocking the scheduler loop.
  """

  use GenServer

  alias Scheduler.{Job, ExecutionLog}

  @type job_id :: String.t()
  @type state :: %{jobs: %{job_id() => Job.t()}, running: MapSet.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(Job.t()) :: :ok | {:error, :duplicate_job_id}
  def register(%Job{id: id} = job) when is_binary(id) do
    GenServer.call(__MODULE__, {:register, job})
  end

  @spec unregister(job_id()) :: :ok | {:error, :not_found}
  def unregister(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:unregister, job_id})
  end

  @spec trigger(job_id()) :: :ok | {:error, :not_found | :already_running}
  def trigger(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:trigger, job_id})
  end

  @spec list_jobs() :: [Job.t()]
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @impl GenServer
  def init(_opts) do
    schedule_tick()
    {:ok, %{jobs: %{}, running: MapSet.new()}}
  end

  @impl GenServer
  def handle_call({:register, job}, _from, %{jobs: jobs} = state) do
    if Map.has_key?(jobs, job.id) do
      {:reply, {:error, :duplicate_job_id}, state}
    else
      {:reply, :ok, %{state | jobs: Map.put(jobs, job.id, job)}}
    end
  end

  def handle_call({:unregister, job_id}, _from, %{jobs: jobs} = state) do
    if Map.has_key?(jobs, job_id) do
      {:reply, :ok, %{state | jobs: Map.delete(jobs, job_id)}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:trigger, job_id}, _from, state) do
    cond do
      not Map.has_key?(state.jobs, job_id) ->
        {:reply, {:error, :not_found}, state}

      MapSet.member?(state.running, job_id) ->
        {:reply, {:error, :already_running}, state}

      true ->
        job = state.jobs[job_id]
        spawn_job(job, self())
        {:reply, :ok, %{state | running: MapSet.put(state.running, job_id)}}
    end
  end

  def handle_call(:list_jobs, _from, state) do
    {:reply, Map.values(state.jobs), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    due_jobs =
      state.jobs
      |> Map.values()
      |> Enum.reject(&MapSet.member?(state.running, &1.id))
      |> Enum.filter(&Job.due?(&1, now))

    new_running =
      Enum.reduce(due_jobs, state.running, fn job, running ->
        spawn_job(job, self())
        MapSet.put(running, job.id)
      end)

    schedule_tick()
    {:noreply, %{state | running: new_running}}
  end

  def handle_info({:job_done, job_id, result}, state) do
    :ok = ExecutionLog.record(job_id, result)
    {:noreply, %{state | running: MapSet.delete(state.running, job_id)}}
  end

  defp spawn_job(%Job{id: id, handler: handler, args: args}, scheduler_pid) do
    Task.start(fn ->
      result = safely_execute(handler, args)
      send(scheduler_pid, {:job_done, id, result})
    end)
  end

  defp safely_execute(handler, args) do
    {:ok, handler.(args)}
  rescue
    err -> {:error, Exception.message(err)}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, :timer.seconds(30))
  end
end

defmodule Scheduler.Job do
  @moduledoc "Struct representing a schedulable recurring job."

  @enforce_keys [:id, :handler, :interval_seconds]
  defstruct [:id, :name, :handler, :args, :interval_seconds, :last_run_at]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          handler: (term() -> term()),
          args: term(),
          interval_seconds: pos_integer(),
          last_run_at: DateTime.t() | nil
        }

  @spec due?(t(), DateTime.t()) :: boolean()
  def due?(%__MODULE__{last_run_at: nil}, _now), do: true

  def due?(%__MODULE__{last_run_at: last, interval_seconds: interval}, now) do
    DateTime.diff(now, last, :second) >= interval
  end
end
```
