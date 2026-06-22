```elixir
defmodule Media.Transcoding.JobSupervisor do
  @moduledoc """
  Supervises media transcoding jobs as dynamically started task children.

  Each transcoding job runs under a `DynamicSupervisor`, limiting
  concurrent transcode operations and enabling per-job fault isolation.
  """

  use DynamicSupervisor

  alias Media.Transcoding.{TranscodeWorker, JobRegistry, JobStatus}

  @max_concurrent_jobs 8

  @doc """
  Starts the transcoding job supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_concurrent_jobs)
  end

  @doc """
  Starts a new transcoding job for the given media asset.

  Returns `{:ok, job_id}` or `{:error, :max_jobs_reached}` if the pool is full.
  """
  @spec start_job(String.t(), map()) :: {:ok, String.t()} | {:error, :max_jobs_reached}
  def start_job(asset_id, transcode_params) when is_binary(asset_id) do
    job_id = generate_job_id(asset_id)

    spec = {TranscodeWorker, job_id: job_id, asset_id: asset_id, params: transcode_params}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} ->
        JobRegistry.register(job_id, asset_id)
        {:ok, job_id}

      {:error, :max_children} ->
        {:error, :max_jobs_reached}
    end
  end

  @doc """
  Returns the current status for a transcoding job.
  """
  @spec job_status(String.t()) :: {:ok, JobStatus.t()} | {:error, :not_found}
  def job_status(job_id) when is_binary(job_id) do
    JobRegistry.lookup_status(job_id)
  end

  @doc """
  Cancels a running transcoding job by job ID.

  Returns `:ok` if cancelled or `{:error, :not_found}` if the job does not exist.
  """
  @spec cancel_job(String.t()) :: :ok | {:error, :not_found}
  def cancel_job(job_id) when is_binary(job_id) do
    case find_worker_pid(job_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        JobRegistry.mark_cancelled(job_id)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a summary of all active transcoding jobs.
  """
  @spec active_jobs() :: [%{job_id: String.t(), asset_id: String.t(), status: atom()}]
  def active_jobs do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} when is_pid(pid) ->
      case JobRegistry.lookup_by_pid(pid) do
        {:ok, info} -> [info]
        :error -> []
      end
    end)
  end

  @doc """
  Returns the number of currently active transcoding jobs.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end

  defp find_worker_pid(job_id) do
    case JobRegistry.lookup_pid(job_id) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp generate_job_id(asset_id) do
    hash = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "#{asset_id}-#{hash}"
  end
end
```
