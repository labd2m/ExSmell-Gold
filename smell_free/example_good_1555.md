```elixir
defmodule Pipeline.Workers.ImageResizer do
  @moduledoc """
  Supervised GenServer managing asynchronous image resizing jobs.

  Each resizer worker maintains a bounded job queue and processes
  resize operations sequentially to avoid memory pressure.
  """

  use GenServer, restart: :permanent

  alias Pipeline.Storage.ObjectStore
  alias Pipeline.Workers.ImageResizer.Job

  @type state :: %{
          queue: :queue.queue(Job.t()),
          processing: boolean(),
          worker_id: String.t()
        }

  @type start_opts :: [worker_id: String.t()]

  @doc """
  Starts a linked image resizer worker under a supervisor.
  """
  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    GenServer.start_link(__MODULE__, %{worker_id: worker_id}, name: via(worker_id))
  end

  @doc """
  Enqueues an image resize job for processing.

  Returns `:ok` immediately; job result is delivered asynchronously
  via the provided `notify_pid`.
  """
  @spec enqueue(String.t(), Job.t()) :: :ok
  def enqueue(worker_id, %Job{} = job) do
    GenServer.cast(via(worker_id), {:enqueue, job})
  end

  @impl GenServer
  def init(%{worker_id: worker_id}) do
    state = %{
      queue: :queue.new(),
      processing: false,
      worker_id: worker_id
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:enqueue, job}, state) do
    updated_queue = :queue.in(job, state.queue)
    new_state = %{state | queue: updated_queue}

    if state.processing do
      {:noreply, new_state}
    else
      {:noreply, process_next(new_state)}
    end
  end

  @impl GenServer
  def handle_info(:job_complete, state) do
    {:noreply, process_next(%{state | processing: false})}
  end

  def handle_info({:job_failed, reason, job}, state) do
    notify_failure(job, reason)
    {:noreply, process_next(%{state | processing: false})}
  end

  defp process_next(%{queue: queue} = state) do
    case :queue.out(queue) do
      {:empty, _} ->
        %{state | processing: false}

      {{:value, job}, remaining_queue} ->
        spawn_resize_task(job)
        %{state | queue: remaining_queue, processing: true}
    end
  end

  defp spawn_resize_task(job) do
    parent = self()

    Task.start(fn ->
      case execute_resize(job) do
        :ok -> send(parent, :job_complete)
        {:error, reason} -> send(parent, {:job_failed, reason, job})
      end
    end)
  end

  defp execute_resize(%Job{source_key: source, target_key: target, dimensions: dims}) do
    with {:ok, image_data} <- ObjectStore.fetch(source),
         {:ok, resized} <- resize_image(image_data, dims),
         :ok <- ObjectStore.put(target, resized) do
      :ok
    end
  end

  defp resize_image(data, %{width: width, height: height}) do
    Image.resize(data, width, height)
  end

  defp notify_failure(%Job{notify_pid: pid} = job, reason) when is_pid(pid) do
    send(pid, {:resize_failed, job.source_key, reason})
  end

  defp notify_failure(_job, _reason), do: :ok

  defp via(worker_id) do
    {:via, Registry, {Pipeline.Workers.Registry, {__MODULE__, worker_id}}}
  end
end
```
