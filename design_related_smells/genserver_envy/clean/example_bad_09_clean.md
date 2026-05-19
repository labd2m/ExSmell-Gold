```elixir
defmodule MyApp.SchedulerAgent do
  @moduledoc """
  In-process job scheduler for recurring background tasks such as
  report generation, data sync, and cache warming.
  """

  use Agent

  alias MyApp.{WorkerPool, AuditLog}
  alias MyApp.Scheduler.{Job, JobRun}

  @tick_interval_ms 60_000

  def start_link(_opts) do
    result = Agent.start_link(fn -> %{jobs: %{}, runs: [], running: MapSet.new()} end, name: __MODULE__)

    if match?({:ok, _}, result) do
      schedule_tick()
    end

    result
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  def list_jobs do
    Agent.get(__MODULE__, & &1.jobs)
  end

  def list_runs do
    Agent.get(__MODULE__, & &1.runs)
  end


  def schedule_job(name, interval_seconds, handler_mfa) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.jobs, name) do
        {{:error, :already_exists}, state}
      else
        job = %Job{
          name: name,
          interval_seconds: interval_seconds,
          handler_mfa: handler_mfa,
          next_run_at: DateTime.utc_now(),
          created_at: DateTime.utc_now(),
          enabled: true
        }

        new_state = put_in(state, [:jobs, name], job)
        {{:ok, job}, new_state}
      end
    end)
  end

  def cancel_job(name) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.jobs, name) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, _job} ->
          new_state = %{state | jobs: Map.delete(state.jobs, name)}
          {:ok, new_state}
      end
    end)
  end

  def tick do
    now = DateTime.utc_now()

    Agent.update(__MODULE__, fn state ->
      due_jobs =
        state.jobs
        |> Map.values()
        |> Enum.filter(fn job ->
          job.enabled and
            not MapSet.member?(state.running, job.name) and
            DateTime.compare(job.next_run_at, now) in [:lt, :eq]
        end)

      Enum.reduce(due_jobs, state, fn job, acc_state ->
        {mod, fun, args} = job.handler_mfa

        WorkerPool.async(fn ->
          run_start = DateTime.utc_now()

          result =
            try do
              apply(mod, fun, args)
              :ok
            rescue
              e -> {:error, Exception.message(e)}
            end

          run = %JobRun{
            job_name: job.name,
            started_at: run_start,
            finished_at: DateTime.utc_now(),
            result: result
          }

          AuditLog.record(:job_run, run)

          Agent.update(__MODULE__, fn s ->
            next = DateTime.add(run_start, job.interval_seconds, :second)
            updated_job = %{job | next_run_at: next}

            %{
              s
              | running: MapSet.delete(s.running, job.name),
                jobs: Map.put(s.jobs, job.name, updated_job),
                runs: [run | Enum.take(s.runs, 999)]
            }
          end)
        end)

        %{acc_state | running: MapSet.put(acc_state.running, job.name)}
      end)
    end)

    schedule_tick()
  end


  def enable_job(name) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:jobs, name], fn job -> job && %{job | enabled: true} end)
    end)
  end

  def disable_job(name) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:jobs, name], fn job -> job && %{job | enabled: false} end)
    end)
  end
end
```
