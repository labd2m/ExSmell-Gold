# Annotated Example 09 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Scheduling.RecurringJob.register/2`
- **Affected function(s):** `register/2`
- **Short explanation:** Each registered recurring job starts its own GenServer via `GenServer.start/3` without a supervisor. A crash in any job process means that cron-style task is silently dropped — the application continues running but the scheduled work stops without any alert or restart.

```elixir
defmodule Scheduling.RecurringJob do
  use GenServer

  @moduledoc """
  Manages a single recurring job defined by a cron-style interval.
  Tracks execution history, last run time, and consecutive failure counts
  to support alerting and backoff policies.
  """

  @max_consecutive_failures 5

  defstruct [
    :job_id,
    :name,
    :interval_ms,
    :handler,
    :status,
    :last_run_at,
    :last_run_result,
    :run_count,
    :failure_count,
    :consecutive_failures
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` registers a long-running
  # scheduling process outside any supervision tree. Scheduled jobs are often critical
  # maintenance tasks (invoicing, data exports, cleanup). If the GenServer crashes
  # (e.g., a handler raises an unexpected error that escapes the rescue block), the
  # job is silently removed from the schedule with no automatic restart, and the
  # recurring work stops indefinitely.
  def register(job_id, opts) do
    state = %__MODULE__{
      job_id: job_id,
      name: Keyword.fetch!(opts, :name),
      interval_ms: Keyword.fetch!(opts, :interval_ms),
      handler: Keyword.fetch!(opts, :handler),
      status: :idle,
      last_run_at: nil,
      last_run_result: nil,
      run_count: 0,
      failure_count: 0,
      consecutive_failures: 0
    }

    GenServer.start(__MODULE__, state, name: via_name(job_id))
  end
  # VALIDATION: SMELL END

  @doc "Triggers the job to run immediately, outside its normal schedule."
  def trigger_now(job_id) do
    GenServer.cast(via_name(job_id), :run_now)
  end

  @doc "Pauses a job, preventing it from running on its next scheduled tick."
  def pause(job_id) do
    GenServer.cast(via_name(job_id), :pause)
  end

  @doc "Resumes a paused job."
  def resume(job_id) do
    GenServer.cast(via_name(job_id), :resume)
  end

  @doc "Returns the current status and run history summary for a job."
  def info(job_id) do
    GenServer.call(via_name(job_id), :info)
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_next_run(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:run, %{status: :paused} = state) do
    schedule_next_run(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:run, state) do
    new_state = execute_job(state)
    schedule_next_run(state.interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:run_now, state) do
    {:noreply, execute_job(state)}
  end

  def handle_cast(:pause, state) do
    {:noreply, %{state | status: :paused}}
  end

  def handle_cast(:resume, state) do
    {:noreply, %{state | status: :idle}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      job_id: state.job_id,
      name: state.name,
      status: state.status,
      last_run_at: state.last_run_at,
      last_run_result: state.last_run_result,
      run_count: state.run_count,
      failure_count: state.failure_count,
      consecutive_failures: state.consecutive_failures
    }

    {:reply, info, state}
  end

  defp execute_job(state) do
    started_at = DateTime.utc_now()

    result =
      try do
        apply(state.handler, [])
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    base = %{
      state
      | last_run_at: started_at,
        last_run_result: result,
        run_count: state.run_count + 1,
        status: :idle
    }

    case result do
      {:ok, _} ->
        %{base | consecutive_failures: 0}

      {:error, _} ->
        new_consec = state.consecutive_failures + 1
        new_state = %{base | failure_count: state.failure_count + 1, consecutive_failures: new_consec}

        if new_consec >= @max_consecutive_failures do
          %{new_state | status: :suspended}
        else
          new_state
        end
    end
  end

  defp schedule_next_run(interval_ms) do
    Process.send_after(self(), :run, interval_ms)
  end

  defp via_name(job_id) do
    {:via, Registry, {Scheduling.JobRegistry, job_id}}
  end
end
```
