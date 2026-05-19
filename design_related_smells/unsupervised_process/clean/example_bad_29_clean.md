```elixir
defmodule JobRunner do
  use GenServer

  @moduledoc """
  Executes a single scheduled background job and tracks its progress.
  Supports timeout enforcement and progress callbacks.
  """

  @default_timeout_ms 30_000

  defstruct [
    :job_id,
    :job_type,
    :payload,
    :started_at,
    :timeout_ms,
    :status,
    :result,
    progress: 0
  ]

  def start(%{job_id: id} = job_spec) do
    GenServer.start(__MODULE__, job_spec, name: via(id))
  end

  def progress(job_id) do
    GenServer.call(via(job_id), :progress)
  end

  def result(job_id) do
    GenServer.call(via(job_id), :result)
  end

  def cancel(job_id) do
    GenServer.call(via(job_id), :cancel)
  end

  defp via(id), do: {:via, Registry, {JobRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{job_id: id, job_type: type, payload: payload} = spec) do
    state = %__MODULE__{
      job_id: id,
      job_type: type,
      payload: payload,
      started_at: DateTime.utc_now(),
      timeout_ms: Map.get(spec, :timeout_ms, @default_timeout_ms),
      status: :running
    }

    send(self(), :execute)
    {:ok, state}
  end

  @impl true
  def handle_call(:progress, _from, state) do
    {:reply, %{percent: state.progress, status: state.status}, state}
  end

  def handle_call(:result, _from, %{status: :completed} = state) do
    {:reply, {:ok, state.result}, state}
  end

  def handle_call(:result, _from, %{status: :failed} = state) do
    {:reply, {:error, state.result}, state}
  end

  def handle_call(:result, _from, state) do
    {:reply, {:pending, state.progress}, state}
  end

  def handle_call(:cancel, _from, state) do
    {:stop, :normal, :cancelled, %{state | status: :cancelled}}
  end

  @impl true
  def handle_info(:execute, state) do
    Process.send_after(self(), :timeout_check, state.timeout_ms)
    result = run_job(state.job_type, state.payload)
    {:noreply, %{state | status: :completed, result: result, progress: 100}}
  end

  def handle_info(:timeout_check, %{status: :running} = state) do
    {:stop, :normal, %{state | status: :failed, result: :timeout}}
  end

  def handle_info(:timeout_check, state), do: {:noreply, state}

  defp run_job(:report_generation, %{report_type: rtype}) do
    Process.sleep(500)
    %{report_type: rtype, rows: 4200, generated_at: DateTime.utc_now()}
  end

  defp run_job(:data_export, %{entity: entity}) do
    Process.sleep(300)
    %{entity: entity, exported: 1_000, format: :csv}
  end

  defp run_job(:email_blast, %{campaign_id: cid}) do
    Process.sleep(800)
    %{campaign_id: cid, sent: 5_000, failed: 12}
  end

  defp run_job(type, _payload) do
    {:error, {:unknown_job_type, type}}
  end
end

defmodule Scheduler do
  @moduledoc "Enqueues and manages background job execution."

  def enqueue(%{job_id: _id, job_type: _type, payload: _payload} = spec) do
    case JobRunner.start(spec) do
      {:ok, _pid} -> {:ok, spec.job_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def await_result(job_id, poll_interval_ms \\ 500, max_attempts \\ 60) do
    do_poll(job_id, poll_interval_ms, max_attempts)
  end

  defp do_poll(_job_id, _interval, 0), do: {:error, :timeout}
  defp do_poll(job_id, interval, attempts) do
    case JobRunner.result(job_id) do
      {:pending, _} ->
        Process.sleep(interval)
        do_poll(job_id, interval, attempts - 1)

      other ->
        other
    end
  end
end
```
