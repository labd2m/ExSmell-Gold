```elixir
defmodule Media.Transcoding.JobSupervisor do
  @moduledoc """
  Dynamically supervises per-job transcoding workers. Each transcoding
  request runs in an isolated, supervised process, ensuring failures
  are contained and jobs can be restarted or monitored independently.
  """

  use DynamicSupervisor

  alias Media.Transcoding.JobWorker

  @doc "Starts the DynamicSupervisor and links to the calling process."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a new transcoding job. Returns `{:ok, pid}` on success.
  Each job is uniquely identified by `job_id`.
  """
  @spec enqueue(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def enqueue(job_id, params) when is_binary(job_id) and is_map(params) do
    spec = {JobWorker, [job_id: job_id, params: params]}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Returns the count of currently active transcoding jobs."
  @spec active_job_count() :: non_neg_integer()
  def active_job_count do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 50)
  end
end

defmodule Media.Transcoding.JobWorker do
  @moduledoc """
  Executes a single media transcoding job. Communicates progress
  via Phoenix.PubSub events. Terminates normally on completion
  or abnormally on unrecoverable errors.
  """

  use GenServer, restart: :transient

  alias Media.Transcoding.{Encoder, ProgressEvent}

  @type state :: %{
          job_id: String.t(),
          params: map(),
          status: :pending | :encoding | :finalizing | :done,
          progress: non_neg_integer()
        }

  @doc "Starts and links the JobWorker to its supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    GenServer.start_link(__MODULE__, opts, name: via(job_id))
  end

  @doc "Returns the current status and progress of a job."
  @spec status(String.t()) :: {:ok, state()} | {:error, :not_found}
  def status(job_id) when is_binary(job_id) do
    case Registry.lookup(Media.Registry, job_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :status)}
      [] -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      job_id: Keyword.fetch!(opts, :job_id),
      params: Keyword.fetch!(opts, :params),
      status: :pending,
      progress: 0
    }

    send(self(), :start_encoding)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info(:start_encoding, state) do
    new_state = %{state | status: :encoding}
    broadcast_progress(new_state)

    case Encoder.start(state.params) do
      {:ok, encoder_ref} ->
        {:noreply, %{new_state | progress: 10}, {:continue, {:poll, encoder_ref}}}

      {:error, reason} ->
        {:stop, {:encoding_failed, reason}, new_state}
    end
  end

  def handle_info({:progress, pct}, state) do
    updated = %{state | progress: pct}
    broadcast_progress(updated)
    {:noreply, updated}
  end

  @impl GenServer
  def handle_continue({:poll, encoder_ref}, state) do
    case Encoder.await(encoder_ref, 60_000) do
      {:ok, _output_path} ->
        done_state = %{state | status: :done, progress: 100}
        broadcast_progress(done_state)
        {:stop, :normal, done_state}

      {:error, reason} ->
        {:stop, {:encoding_failed, reason}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec broadcast_progress(state()) :: :ok | {:error, term()}
  defp broadcast_progress(state) do
    event = %ProgressEvent{job_id: state.job_id, status: state.status, progress: state.progress}
    Phoenix.PubSub.broadcast(Media.PubSub, "jobs:#{state.job_id}", {:job_progress, event})
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  defp via(job_id), do: {:via, Registry, {Media.Registry, job_id}}
end
```
