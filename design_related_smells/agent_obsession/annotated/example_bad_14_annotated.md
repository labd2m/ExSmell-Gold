# Code Smell Example 14

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `JobQueue`, `WorkerPool`, `JobMonitor`, and `JobResultCollector`
- **Affected functions:** `JobQueue.push/2`, `WorkerPool.claim_job/1`, `JobMonitor.heartbeat/2`, `JobResultCollector.store_result/3`
- **Short explanation:** The Agent backing the background job queue is directly accessed from four separate modules. No single module owns the Agent interface, so job lifecycle transitions (pending → claimed → done/failed) are scattered, making it difficult to enforce state machine rules or reason about concurrency.

```elixir
defmodule JobQueue do
  @moduledoc """
  In-memory background job queue backed by an Agent process.
  """

  defstruct [:id, :type, :payload, :status, :claimed_by, :result, :inserted_at]

  def start_link do
    Agent.start_link(fn -> %{jobs: %{}, sequence: 0} end, name: __MODULE__)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because JobQueue directly writes to the Agent, while
  # WorkerPool, JobMonitor, and JobResultCollector also directly access the same Agent,
  # spreading state ownership across unrelated modules.
  def push(pid, type, payload) do
    Agent.get_and_update(pid, fn %{jobs: jobs, sequence: seq} = state ->
      id = seq + 1

      job = %__MODULE__{
        id: id,
        type: type,
        payload: payload,
        status: :pending,
        claimed_by: nil,
        result: nil,
        inserted_at: DateTime.utc_now()
      }

      new_state = %{state | jobs: Map.put(jobs, id, job), sequence: id}
      {id, new_state}
    end)
  end

  def pending_jobs(pid) do
    Agent.get(pid, fn %{jobs: jobs} ->
      jobs |> Map.values() |> Enum.filter(&(&1.status == :pending))
    end)
  end
  # VALIDATION: SMELL END
end

defmodule WorkerPool do
  @moduledoc """
  Simulates a pool of workers that claim and execute jobs.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because WorkerPool directly transitions job state inside
  # the Agent from :pending to :claimed, instead of using a centralized JobQueue API.
  def claim_job(pid) do
    worker_id = self() |> inspect()

    Agent.get_and_update(pid, fn %{jobs: jobs} = state ->
      case Enum.find(jobs, fn {_, j} -> j.status == :pending end) do
        nil ->
          {:none, state}

        {id, job} ->
          claimed = %{job | status: :claimed, claimed_by: worker_id}
          {{:ok, claimed}, %{state | jobs: Map.put(jobs, id, claimed)}}
      end
    end)
  end
  # VALIDATION: SMELL END

  def execute(%{type: "send_email", payload: payload}) do
    IO.puts("Sending email: #{inspect(payload)}")
    {:ok, %{sent: true}}
  end

  def execute(%{type: "generate_report", payload: payload}) do
    IO.puts("Generating report: #{inspect(payload)}")
    {:ok, %{report_id: :rand.uniform(9999)}}
  end

  def execute(%{type: type}), do: {:error, {:unknown_type, type}}
end

defmodule JobMonitor do
  @moduledoc """
  Tracks job heartbeats and detects stalled workers.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because JobMonitor directly modifies Agent state to
  # update heartbeat timestamps, introducing yet another direct Agent access site.
  def heartbeat(pid, job_id) do
    Agent.update(pid, fn %{jobs: jobs} = state ->
      case Map.fetch(jobs, job_id) do
        {:ok, job} ->
          updated = Map.put(job, :last_heartbeat, System.system_time(:second))
          %{state | jobs: Map.put(jobs, job_id, updated)}

        :error ->
          state
      end
    end)
  end

  def stalled_jobs(pid, timeout_seconds \\ 30) do
    now = System.system_time(:second)

    Agent.get(pid, fn %{jobs: jobs} ->
      jobs
      |> Map.values()
      |> Enum.filter(fn job ->
        job.status == :claimed and
          is_integer(job[:last_heartbeat]) and
          now - job[:last_heartbeat] > timeout_seconds
      end)
    end)
  end
  # VALIDATION: SMELL END
end

defmodule JobResultCollector do
  @moduledoc """
  Stores execution results and marks jobs as done or failed.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because JobResultCollector directly finalizes job state
  # in the Agent, adding a fourth module that directly mutates Agent-managed data.
  def store_result(pid, job_id, {:ok, result}) do
    Agent.update(pid, fn %{jobs: jobs} = state ->
      case Map.fetch(jobs, job_id) do
        {:ok, job} ->
          finished = %{job | status: :done, result: result}
          %{state | jobs: Map.put(jobs, job_id, finished)}

        :error ->
          state
      end
    end)
  end

  def store_result(pid, job_id, {:error, reason}) do
    Agent.update(pid, fn %{jobs: jobs} = state ->
      case Map.fetch(jobs, job_id) do
        {:ok, job} ->
          finished = %{job | status: :failed, result: %{error: reason}}
          %{state | jobs: Map.put(jobs, job_id, finished)}

        :error ->
          state
      end
    end)
  end

  def completed_summary(pid) do
    Agent.get(pid, fn %{jobs: jobs} ->
      jobs
      |> Map.values()
      |> Enum.group_by(& &1.status)
      |> Map.new(fn {k, v} -> {k, length(v)} end)
    end)
  end
  # VALIDATION: SMELL END
end
```
