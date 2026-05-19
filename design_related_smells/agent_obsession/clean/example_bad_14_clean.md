```elixir
defmodule JobQueue do
  @moduledoc """
  In-memory background job queue backed by an Agent process.
  """

  defstruct [:id, :type, :payload, :status, :claimed_by, :result, :inserted_at]

  def start_link do
    Agent.start_link(fn -> %{jobs: %{}, sequence: 0} end, name: __MODULE__)
  end

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
end

defmodule WorkerPool do
  @moduledoc """
  Simulates a pool of workers that claim and execute jobs.
  """

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
end

defmodule JobResultCollector do
  @moduledoc """
  Stores execution results and marks jobs as done or failed.
  """

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
end
```
