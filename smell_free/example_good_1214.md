```elixir
defmodule Scheduler.CronJob do
  @moduledoc """
  Represents a named recurring job with a fixed interval and a
  module-level callback to invoke on each tick.
  """

  @enforce_keys [:name, :interval_ms, :module, :function]
  defstruct [:name, :interval_ms, :module, :function, :args, :last_run_at]

  @type t :: %__MODULE__{
          name: atom(),
          interval_ms: pos_integer(),
          module: module(),
          function: atom(),
          args: list(),
          last_run_at: integer() | nil
        }

  @spec new(atom(), pos_integer(), module(), atom(), list()) :: t()
  def new(name, interval_ms, module, function, args \\ [])
      when is_atom(name) and is_integer(interval_ms) and interval_ms > 0 and
             is_atom(module) and is_atom(function) and is_list(args) do
    %__MODULE__{
      name: name,
      interval_ms: interval_ms,
      module: module,
      function: function,
      args: args,
      last_run_at: nil
    }
  end
end

defmodule Scheduler.Runner do
  @moduledoc """
  Manages a set of registered cron-style jobs, firing each callback
  at its configured interval. Jobs are registered at startup via
  application configuration and may be added at runtime.
  All job execution happens inside supervised `Task` calls so a single
  failure never affects other scheduled jobs.
  """

  use GenServer

  require Logger

  alias Scheduler.CronJob

  @tick_ms 1_000

  @type state :: %{jobs: %{atom() => CronJob.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(CronJob.t()) :: :ok | {:error, :duplicate}
  def register(%CronJob{} = job) do
    GenServer.call(__MODULE__, {:register, job})
  end

  @spec unregister(atom()) :: :ok | {:error, :not_found}
  def unregister(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @spec list() :: list(CronJob.t())
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @impl GenServer
  def init(opts) do
    jobs =
      opts
      |> Keyword.get(:jobs, [])
      |> Map.new(fn %CronJob{name: name} = job -> {name, job} end)

    schedule_tick()
    {:ok, %{jobs: jobs}}
  end

  @impl GenServer
  def handle_call({:register, %CronJob{name: name} = job}, _from, %{jobs: jobs} = state) do
    if Map.has_key?(jobs, name) do
      {:reply, {:error, :duplicate}, state}
    else
      {:reply, :ok, %{state | jobs: Map.put(jobs, name, job)}}
    end
  end

  def handle_call({:unregister, name}, _from, %{jobs: jobs} = state) do
    if Map.has_key?(jobs, name) do
      {:reply, :ok, %{state | jobs: Map.delete(jobs, name)}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, %{jobs: jobs} = state) do
    {:reply, Map.values(jobs), state}
  end

  @impl GenServer
  def handle_info(:tick, %{jobs: jobs} = state) do
    now = System.monotonic_time(:millisecond)
    updated_jobs = Map.new(jobs, fn {name, job} -> {name, maybe_run(job, now)} end)
    schedule_tick()
    {:noreply, %{state | jobs: updated_jobs}}
  end

  defp maybe_run(%CronJob{last_run_at: nil} = job, now) do
    execute(job)
    %{job | last_run_at: now}
  end

  defp maybe_run(%CronJob{last_run_at: last, interval_ms: interval} = job, now)
       when now - last >= interval do
    execute(job)
    %{job | last_run_at: now}
  end

  defp maybe_run(job, _now), do: job

  defp execute(%CronJob{name: name, module: mod, function: fun, args: args}) do
    Task.Supervisor.start_child(Scheduler.TaskSupervisor, fn ->
      apply(mod, fun, args)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("Job dispatch failed", job: name, reason: inspect(reason))
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end
end
```
