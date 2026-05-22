```elixir
defmodule Scheduler.JobPoller do
  @moduledoc """
  Periodically polls the job queue for pending work and dispatches
  each job to the appropriate worker process. The polling interval
  is controlled by application configuration.
  """

  use GenServer

  require Logger

  @poll_interval_ms Application.fetch_env!(:scheduler, :poll_interval_ms)

  @max_jobs_per_tick 50
  @stale_job_threshold_seconds 300

  defstruct [
    :node_id,
    :last_poll_at,
    jobs_dispatched: 0,
    jobs_failed: 0
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, node() |> to_string())

    Logger.info("JobPoller starting",
      node_id: node_id,
      poll_interval_ms: @poll_interval_ms
    )

    schedule_tick()

    state = %__MODULE__{
      node_id: node_id,
      last_poll_at: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    new_state = poll_and_dispatch(state)
    schedule_tick()
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    reply = %{
      node_id: state.node_id,
      last_poll_at: state.last_poll_at,
      jobs_dispatched: state.jobs_dispatched,
      jobs_failed: state.jobs_failed,
      poll_interval_ms: @poll_interval_ms
    }

    {:reply, reply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp poll_and_dispatch(state) do
    now = DateTime.utc_now()

    case job_queue().fetch_pending(limit: @max_jobs_per_tick) do
      {:ok, []} ->
        Logger.debug("No pending jobs", node_id: state.node_id)
        %{state | last_poll_at: now}

      {:ok, jobs} ->
        Logger.info("Dispatching jobs", count: length(jobs), node_id: state.node_id)

        {dispatched, failed} =
          Enum.reduce(jobs, {0, 0}, fn job, {d, f} ->
            case dispatch_job(job) do
              :ok -> {d + 1, f}
              {:error, _} -> {d, f + 1}
            end
          end)

        %{
          state
          | last_poll_at: now,
            jobs_dispatched: state.jobs_dispatched + dispatched,
            jobs_failed: state.jobs_failed + failed
        }

      {:error, reason} ->
        Logger.error("Failed to fetch jobs", reason: inspect(reason), node_id: state.node_id)
        state
    end
  end

  defp dispatch_job(%{id: id, type: type, payload: payload}) do
    case worker_for(type) do
      {:ok, worker_mod} ->
        Task.Supervisor.start_child(Scheduler.TaskSupervisor, fn ->
          worker_mod.perform(id, payload)
        end)

        job_queue().mark_running(id)
        :ok

      {:error, :unknown_type} ->
        Logger.warning("No worker for job type", type: type, job_id: id)
        job_queue().mark_failed(id, "unknown_type")
        {:error, :unknown_worker}
    end
  end

  defp worker_for(type) do
    registry = Application.get_env(:scheduler, :worker_registry, %{})

    case Map.fetch(registry, type) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :unknown_type}
    end
  end

  defp reap_stale_jobs do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_job_threshold_seconds, :second)
    job_queue().fail_stale(cutoff)
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @poll_interval_ms)
  end

  defp job_queue, do: Application.get_env(:scheduler, :job_queue, Scheduler.JobQueue)
end
```
