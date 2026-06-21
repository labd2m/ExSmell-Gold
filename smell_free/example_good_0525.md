```elixir
defmodule Media.TranscodeQueue do
  @moduledoc """
  Manages a bounded queue of video transcode jobs backed by a GenServer.
  Jobs are processed serially to avoid resource contention. Each job
  delegates encoding work to a short-lived Task so the queue process
  remains responsive to status queries during encoding. Completed and
  failed job records are retained for auditing.
  """

  use GenServer

  require Logger

  @type job_id :: String.t()
  @type job_status :: :queued | :processing | :done | :failed
  @type job :: %{
          id: job_id(),
          source_path: String.t(),
          output_path: String.t(),
          profile: String.t(),
          status: job_status(),
          queued_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          error: String.t() | nil
        }

  @max_queue_depth 100

  @doc "Starts the transcode queue registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueues a transcode job. Returns the job ID or an error when the queue is full."
  @spec enqueue(String.t(), String.t(), String.t()) ::
          {:ok, job_id()} | {:error, :queue_full}
  def enqueue(source_path, output_path, profile)
      when is_binary(source_path) and is_binary(output_path) and is_binary(profile) do
    GenServer.call(__MODULE__, {:enqueue, source_path, output_path, profile})
  end

  @doc "Fetches the status record for a job by its ID."
  @spec fetch_job(job_id()) :: {:ok, job()} | {:error, :not_found}
  def fetch_job(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:fetch, job_id})
  end

  @doc "Returns all jobs currently in the queue or recently processed."
  @spec list_jobs() :: [job()]
  def list_jobs, do: GenServer.call(__MODULE__, :list_jobs)

  @impl GenServer
  def init(_opts) do
    {:ok, %{queue: :queue.new(), jobs: %{}, current_task: nil}}
  end

  @impl GenServer
  def handle_call({:enqueue, source, output, profile}, _from, state) do
    if :queue.len(state.queue) >= @max_queue_depth do
      {:reply, {:error, :queue_full}, state}
    else
      job = build_job(source, output, profile)
      new_queue = :queue.in(job.id, state.queue)
      new_jobs = Map.put(state.jobs, job.id, job)
      new_state = maybe_start_next(%{state | queue: new_queue, jobs: new_jobs})
      {:reply, {:ok, job.id}, new_state}
    end
  end

  def handle_call({:fetch, job_id}, _from, state) do
    result = case Map.get(state.jobs, job_id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
    {:reply, result, state}
  end

  def handle_call(:list_jobs, _from, state) do
    {:reply, Map.values(state.jobs), state}
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    new_state = handle_task_result(result, state)
    {:noreply, maybe_start_next(%{new_state | current_task: nil})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    new_state = handle_task_result({:error, {:crashed, reason}}, state)
    {:noreply, maybe_start_next(%{new_state | current_task: nil})}
  end

  defp maybe_start_next(%{current_task: task} = state) when not is_nil(task), do: state

  defp maybe_start_next(%{queue: q} = state) do
    case :queue.out(q) do
      {{:value, job_id}, rest} ->
        task = Task.async(fn -> run_transcode(Map.fetch!(state.jobs, job_id)) end)
        new_jobs = update_job(state.jobs, job_id, :processing, nil, nil)
        %{state | queue: rest, jobs: new_jobs, current_task: task.ref}

      {:empty, _} ->
        state
    end
  end

  defp handle_task_result({:ok, job_id}, state) do
    %{state | jobs: update_job(state.jobs, job_id, :done, DateTime.utc_now(), nil)}
  end

  defp handle_task_result({:error, {job_id, reason}}, state) do
    %{state | jobs: update_job(state.jobs, job_id, :failed, DateTime.utc_now(), inspect(reason))}
  end

  defp handle_task_result(_, state), do: state

  defp run_transcode(%{id: id, source_path: src, output_path: out, profile: profile}) do
    Logger.info("[TranscodeQueue] Starting #{profile} transcode for job #{id}")
    case System.cmd("ffmpeg", ["-i", src, "-preset", profile, out], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, id}
      {output, code} -> {:error, {id, {:ffmpeg_exit, code, String.slice(output, 0, 200)}}}
    end
  rescue
    e -> {:error, {nil, Exception.message(e)}}
  end

  defp build_job(source, output, profile) do
    %{id: generate_id(), source_path: source, output_path: output, profile: profile,
      status: :queued, queued_at: DateTime.utc_now(), finished_at: nil, error: nil}
  end

  defp update_job(jobs, job_id, status, finished_at, error) do
    Map.update!(jobs, job_id, fn j ->
      %{j | status: status, finished_at: finished_at, error: error}
    end)
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
```
