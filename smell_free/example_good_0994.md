```elixir
defmodule Queue.PriorityDispatcher do
  @moduledoc """
  A supervised GenServer that dispatches work from a PostgreSQL-backed priority
  queue with three lanes: `:critical`, `:standard`, and `:bulk`. The dispatcher
  polls each lane using `SELECT FOR UPDATE SKIP LOCKED` and allocates worker
  slots proportionally — critical jobs always get capacity first, then standard,
  then bulk with whatever remains. This prevents bulk imports from starving
  time-sensitive operations without completely blocking them.
  """

  use GenServer

  alias Queue.{Job, Repo}
  import Ecto.Query

  require Logger

  @slot_allocation %{critical: 0.5, standard: 0.35, bulk: 0.15}
  @poll_interval_ms 500
  @default_total_slots 20

  @type priority :: :critical | :standard | :bulk
  @type handler :: (Job.t() -> :ok | {:error, term()})

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns a map of currently running job counts per priority lane.
  """
  @spec running_counts(GenServer.server()) :: %{priority() => non_neg_integer()}
  def running_counts(server \\ __MODULE__) do
    GenServer.call(server, :running_counts)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    total_slots = Keyword.get(opts, :total_slots, @default_total_slots)
    handler = Keyword.fetch!(opts, :handler)

    {:ok, task_sup} = Task.Supervisor.start_link()

    state = %{
      total_slots: total_slots,
      handler: handler,
      task_sup: task_sup,
      running: %{critical: 0, standard: 0, bulk: 0}
    }

    schedule_poll()
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:running_counts, _from, state) do
    {:reply, state.running, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state = dispatch_available(state)
    schedule_poll()
    {:noreply, new_state}
  end

  def handle_info({:job_done, priority, result, job}, state) do
    log_result(result, job, priority)
    new_running = Map.update!(state.running, priority, &max(0, &1 - 1))
    {:noreply, %{state | running: new_running}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dispatch_available(state) do
    total_in_use = state.running |> Map.values() |> Enum.sum()
    available = max(0, state.total_slots - total_in_use)

    if available == 0 do
      state
    else
      slots_per_priority = compute_slots(available, state.running)
      dispatch_lanes(state, slots_per_priority)
    end
  end

  defp compute_slots(available, running) do
    Map.new(@slot_allocation, fn {priority, ratio} ->
      already_running = Map.get(running, priority, 0)
      max_for_priority = round(available * ratio)
      {priority, max(0, max_for_priority - already_running)}
    end)
  end

  defp dispatch_lanes(state, slots_per_priority) do
    Enum.reduce(slots_per_priority, state, fn {priority, slots}, acc ->
      jobs = claim_jobs(priority, slots)
      Enum.reduce(jobs, acc, &dispatch_job(&2, &1, priority))
    end)
  end

  defp claim_jobs(_priority, 0), do: []

  defp claim_jobs(priority, limit) do
    Repo.transaction(fn ->
      ids =
        Job
        |> where([j], j.priority == ^priority and j.status == :pending)
        |> order_by([j], asc: j.inserted_at)
        |> limit(^limit)
        |> select([j], j.id)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      {_count, jobs} =
        Job
        |> where([j], j.id in ^ids)
        |> update([j], set: [status: :running])
        |> select([j], j)
        |> Repo.update_all([])

      jobs
    end)
    |> case do
      {:ok, jobs} -> jobs
      {:error, _} -> []
    end
  end

  defp dispatch_job(state, job, priority) do
    parent = self()
    handler = state.handler

    Task.Supervisor.start_child(state.task_sup, fn ->
      result = handler.(job)
      send(parent, {:job_done, priority, result, job})
    end)

    new_running = Map.update!(state.running, priority, &(&1 + 1))
    %{state | running: new_running}
  end

  defp log_result(:ok, job, priority) do
    Logger.debug("Job completed", job_id: job.id, priority: priority)
  end

  defp log_result({:error, reason}, job, priority) do
    Logger.warning("Job failed", job_id: job.id, priority: priority, reason: inspect(reason))
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
```
