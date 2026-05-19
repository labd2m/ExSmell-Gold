```elixir
defmodule Reporting.JobWorker do
  use GenServer

  @moduledoc """
  Executes a single report generation job asynchronously.
  Manages job state transitions, progress tracking, and
  artifact storage for downloadable reports.
  """

  @progress_interval_ms 2_000

  defstruct [
    :job_id,
    :report_type,
    :parameters,
    :requested_by,
    :status,
    :progress,
    :started_at,
    :completed_at,
    :artifact_path,
    :error
  ]

  def start(job_params) do
    job_id = generate_job_id()

    state = %__MODULE__{
      job_id: job_id,
      report_type: job_params.report_type,
      parameters: job_params.parameters,
      requested_by: job_params.user_id,
      status: :queued,
      progress: 0,
      started_at: nil,
      completed_at: nil,
      artifact_path: nil,
      error: nil
    }

    GenServer.start(__MODULE__, state, name: via_name(job_id))
    {:ok, job_id}
  end

  @doc "Returns the current status and progress of a job."
  def status(job_id) do
    case GenServer.whereis(via_name(job_id)) do
      nil -> {:error, :not_found}
      _pid -> {:ok, GenServer.call(via_name(job_id), :status)}
    end
  end

  @doc "Requests cancellation of a running job."
  def cancel(job_id) do
    GenServer.cast(via_name(job_id), :cancel)
  end

  @doc "Retrieves the artifact path once the job is complete."
  def get_artifact(job_id) do
    GenServer.call(via_name(job_id), :get_artifact)
  end

  ## Callbacks

  @impl true
  def init(state) do
    send(self(), :begin)
    {:ok, state}
  end

  @impl true
  def handle_info(:begin, state) do
    new_state = %{state | status: :running, started_at: DateTime.utc_now(), progress: 0}
    schedule_progress_tick()
    send(self(), :execute)
    {:noreply, new_state}
  end

  def handle_info(:execute, state) do
    case state.status do
      :running ->
        result = execute_report(state.report_type, state.parameters)
        handle_execution_result(state, result)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:progress_tick, state) do
    if state.status == :running do
      simulated_progress = min(state.progress + :rand.uniform(15), 95)
      schedule_progress_tick()
      {:noreply, %{state | progress: simulated_progress}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    summary = %{
      job_id: state.job_id,
      report_type: state.report_type,
      status: state.status,
      progress: state.progress,
      started_at: state.started_at,
      completed_at: state.completed_at,
      error: state.error
    }

    {:reply, summary, state}
  end

  def handle_call(:get_artifact, _from, state) do
    case state.status do
      :completed -> {:reply, {:ok, state.artifact_path}, state}
      :failed -> {:reply, {:error, state.error}, state}
      other -> {:reply, {:error, {:not_ready, other}}, state}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    if state.status in [:queued, :running] do
      {:noreply, %{state | status: :cancelled, completed_at: DateTime.utc_now()}}
    else
      {:noreply, state}
    end
  end

  defp handle_execution_result(state, {:ok, path}) do
    new_state = %{
      state
      | status: :completed,
        progress: 100,
        artifact_path: path,
        completed_at: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  defp handle_execution_result(state, {:error, reason}) do
    new_state = %{
      state
      | status: :failed,
        error: reason,
        completed_at: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  defp execute_report(_type, _params) do
    Process.sleep(100)
    {:ok, "/reports/output_#{:rand.uniform(999_999)}.csv"}
  end

  defp schedule_progress_tick do
    Process.send_after(self(), :progress_tick, @progress_interval_ms)
  end

  defp via_name(job_id) do
    {:via, Registry, {Reporting.JobRegistry, job_id}}
  end

  defp generate_job_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
