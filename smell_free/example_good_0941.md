```elixir
defmodule JobTracker.Job do
  @moduledoc false

  @type status :: :queued | :running | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          status: status(),
          progress: non_neg_integer(),
          total: non_neg_integer() | nil,
          result: term(),
          error: term(),
          queued_at: integer(),
          started_at: integer() | nil,
          finished_at: integer() | nil,
          worker_pid: pid() | nil
        }

  defstruct [
    :id, :name, :result, :error, :total, :worker_pid,
    :started_at, :finished_at,
    status: :queued, progress: 0, queued_at: 0
  ]

  @spec duration_ms(t()) :: non_neg_integer() | nil
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{started_at: s, finished_at: nil}) do
    System.monotonic_time(:millisecond) - s
  end
  def duration_ms(%__MODULE__{started_at: s, finished_at: f}), do: f - s
end

defmodule JobTracker do
  @moduledoc """
  Tracks long-running background jobs with progress, status, and cancellation.

  Workers call `start/2` to register a job and receive an ID, then report
  incremental progress via `update_progress/3`. On completion or failure,
  `complete/2` or `fail/2` finalises the record. Callers can cancel a
  running job via `cancel/1`; the worker receives a `{:cancel, job_id}`
  message and is responsible for stopping cleanly.
  """

  use GenServer

  alias JobTracker.Job

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(String.t(), pid()) :: {:ok, String.t()}
  def enqueue(name, worker_pid \\ self())
      when is_binary(name) and is_pid(worker_pid) do
    GenServer.call(__MODULE__, {:enqueue, name, worker_pid})
  end

  @spec start_job(String.t()) :: :ok | {:error, :not_found}
  def start_job(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:start, id})
  end

  @spec update_progress(String.t(), non_neg_integer(), non_neg_integer() | nil) :: :ok
  def update_progress(id, progress, total \\ nil) when is_binary(id) do
    GenServer.cast(__MODULE__, {:progress, id, progress, total})
  end

  @spec complete(String.t(), term()) :: :ok
  def complete(id, result \\ nil) when is_binary(id) do
    GenServer.cast(__MODULE__, {:complete, id, result})
  end

  @spec fail(String.t(), term()) :: :ok
  def fail(id, error) when is_binary(id) do
    GenServer.cast(__MODULE__, {:fail, id, error})
  end

  @spec cancel(String.t()) :: :ok | {:error, :not_found | :already_finished}
  def cancel(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:cancel, id})
  end

  @spec get(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @spec list(JobTracker.Job.status() | :all) :: [Job.t()]
  def list(status \\ :all) do
    GenServer.call(__MODULE__, {:list, status})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{jobs: %{}}}

  @impl GenServer
  def handle_call({:enqueue, name, worker_pid}, _from, state) do
    id = generate_id()
    job = %Job{id: id, name: name, worker_pid: worker_pid, queued_at: monotonic_ms()}
    ref = Process.monitor(worker_pid)
    {:reply, {:ok, id}, %{state | jobs: Map.put(state.jobs, id, {job, ref})}}
  end

  def handle_call({:start, id}, _from, state) do
    reply_with_update(state, id, fn job ->
      %{job | status: :running, started_at: monotonic_ms()}
    end)
  end

  def handle_call({:cancel, id}, _from, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, {%Job{status: s}, _}} when s in [:completed, :failed, :cancelled] ->
        {:reply, {:error, :already_finished}, state}

      {:ok, {%Job{worker_pid: pid} = job, ref}} ->
        send(pid, {:cancel, id})
        updated = %{job | status: :cancelled, finished_at: monotonic_ms()}
        {:reply, :ok, %{state | jobs: Map.put(state.jobs, id, {updated, ref})}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, {job, _}} -> {:ok, job}
        :error -> {:error, :not_found}
      end
    {:reply, reply, state}
  end

  def handle_call({:list, :all}, _from, state) do
    {:reply, Enum.map(state.jobs, fn {_, {job, _}} -> job end), state}
  end

  def handle_call({:list, status}, _from, state) do
    jobs = for {_, {%Job{status: ^status} = job, _}} <- state.jobs, do: job
    {:reply, jobs, state}
  end

  @impl GenServer
  def handle_cast({:progress, id, progress, total}, state) do
    {_, new_state} = reply_with_update(state, id, fn job ->
      %{job | progress: progress, total: total || job.total}
    end)
    {:noreply, new_state}
  end

  def handle_cast({:complete, id, result}, state) do
    {_, new_state} = reply_with_update(state, id, fn job ->
      %{job | status: :completed, result: result, finished_at: monotonic_ms()}
    end)
    {:noreply, new_state}
  end

  def handle_cast({:fail, id, error}, state) do
    {_, new_state} = reply_with_update(state, id, fn job ->
      %{job | status: :failed, error: error, finished_at: monotonic_ms()}
    end)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    updated_jobs =
      Map.new(state.jobs, fn
        {id, {%Job{status: :running} = job, ^ref}} ->
          {id, {%{job | status: :failed, error: {:worker_exit, reason}, finished_at: monotonic_ms()}, ref}}
        entry -> entry
      end)
    {:noreply, %{state | jobs: updated_jobs}}
  end

  defp reply_with_update(state, id, fun) do
    case Map.fetch(state.jobs, id) do
      {:ok, {job, ref}} ->
        updated = {fun.(job), ref}
        new_state = %{state | jobs: Map.put(state.jobs, id, updated)}
        {:reply, :ok, new_state}
      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
```
