```elixir
defmodule Exports.AsyncExporter do
  @moduledoc """
  Manages long-running data export jobs asynchronously. Each job is tracked
  by a UUID, runs in a supervised task, and transitions through defined
  status states. Callers poll for completion rather than blocking. The
  completed file path or error reason is stored so clients can retrieve
  results after the task has finished.
  """

  use GenServer

  require Logger

  alias Exports.StorageWriter

  @type job_id :: String.t()
  @type export_format :: :csv | :json | :xlsx
  @type job_status :: :queued | :running | :done | :failed
  @type job :: %{
          id: job_id(),
          format: export_format(),
          filters: map(),
          status: job_status(),
          output_path: String.t() | nil,
          error: String.t() | nil,
          queued_at: DateTime.t(),
          finished_at: DateTime.t() | nil
        }

  @doc "Starts the async exporter registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueues a new export job. Returns the job ID for polling."
  @spec enqueue(export_format(), map()) :: {:ok, job_id()}
  def enqueue(format, filters)
      when format in [:csv, :json, :xlsx] and is_map(filters) do
    GenServer.call(__MODULE__, {:enqueue, format, filters})
  end

  @doc "Returns the current state of an export job."
  @spec status(job_id()) :: {:ok, job()} | {:error, :not_found}
  def status(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:status, job_id})
  end

  @doc "Returns all jobs in reverse-chronological order."
  @spec list_jobs(keyword()) :: [job()]
  def list_jobs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    GenServer.call(__MODULE__, {:list_jobs, limit})
  end

  @impl GenServer
  def init(opts) do
    supervisor = Keyword.get(opts, :task_supervisor, Exports.TaskSupervisor)
    {:ok, %{jobs: %{}, supervisor: supervisor}}
  end

  @impl GenServer
  def handle_call({:enqueue, format, filters}, _from, state) do
    job_id = generate_id()
    job = build_job(job_id, format, filters)
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> run_export(job) end)
    new_jobs = Map.put(state.jobs, job_id, {job, task.ref})
    {:reply, {:ok, job_id}, %{state | jobs: new_jobs}}
  end

  def handle_call({:status, job_id}, _from, state) do
    result =
      case Map.get(state.jobs, job_id) do
        nil -> {:error, :not_found}
        {job, _ref} -> {:ok, job}
      end

    {:reply, result, state}
  end

  def handle_call({:list_jobs, limit}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.map(fn {job, _ref} -> job end)
      |> Enum.sort_by(& &1.queued_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, jobs, state}
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    new_jobs = update_job_result(state.jobs, ref, result)
    {:noreply, %{state | jobs: new_jobs}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    new_jobs = update_job_result(state.jobs, ref, {:error, inspect(reason)})
    {:noreply, %{state | jobs: new_jobs}}
  end

  defp run_export(%{id: id, format: format, filters: filters} = _job) do
    Logger.info("[AsyncExporter] Running #{format} export for job #{id}")
    output_path = "/tmp/exports/#{id}.#{format}"
    File.mkdir_p!(Path.dirname(output_path))
    StorageWriter.write(format, filters, output_path)
    {:ok, id, output_path}
  rescue
    e -> {:error, id, Exception.message(e)}
  end

  defp update_job_result(jobs, ref, result) do
    Map.new(jobs, fn {job_id, {job, task_ref}} ->
      if task_ref == ref do
        updated = apply_result(job, result)
        {job_id, {updated, task_ref}}
      else
        {job_id, {job, task_ref}}
      end
    end)
  end

  defp apply_result(job, {:ok, _id, path}) do
    %{job | status: :done, output_path: path, finished_at: DateTime.utc_now()}
  end

  defp apply_result(job, {:error, _id, reason}) do
    %{job | status: :failed, error: reason, finished_at: DateTime.utc_now()}
  end

  defp apply_result(job, _), do: %{job | status: :failed, finished_at: DateTime.utc_now()}

  defp build_job(id, format, filters) do
    %{id: id, format: format, filters: filters, status: :running,
      output_path: nil, error: nil, queued_at: DateTime.utc_now(), finished_at: nil}
  end

  defp generate_id, do: :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
end
```
