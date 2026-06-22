```elixir
defmodule Media.TranscodeQueue do
  @moduledoc """
  Manages a bounded queue of media transcoding jobs dispatched to pooled workers.
  Provides backpressure by rejecting new jobs when the queue is at capacity.
  """

  use GenServer

  alias Media.TranscodeWorker

  @type job :: %{id: String.t(), source_url: String.t(), target_format: String.t(), submitted_at: DateTime.t()}
  @type job_status :: :queued | :processing | :done | :failed
  @type tracked_job :: %{job: job(), status: job_status(), result: term()}
  @type state :: %{queue: :queue.queue(), jobs: %{String.t() => tracked_job()}, max_queue: pos_integer(), active: non_neg_integer(), max_workers: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(String.t(), String.t()) :: {:ok, String.t()} | {:error, :queue_full}
  def enqueue(source_url, target_format)
      when is_binary(source_url) and is_binary(target_format) do
    GenServer.call(__MODULE__, {:enqueue, source_url, target_format})
  end

  @spec job_status(String.t()) :: {:ok, tracked_job()} | {:error, :not_found}
  def job_status(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:status, job_id})
  end

  @spec queue_depth() :: non_neg_integer()
  def queue_depth, do: GenServer.call(__MODULE__, :depth)

  @impl GenServer
  def init(opts) do
    state = %{
      queue: :queue.new(),
      jobs: %{},
      max_queue: Keyword.get(opts, :max_queue, 100),
      active: 0,
      max_workers: Keyword.get(opts, :max_workers, 4)
    }
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:enqueue, source_url, target_format}, _from, state) do
    if :queue.len(state.queue) >= state.max_queue do
      {:reply, {:error, :queue_full}, state}
    else
      job = build_job(source_url, target_format)
      tracked = %{job: job, status: :queued, result: nil}
      new_state = %{state |
        queue: :queue.in(job, state.queue),
        jobs: Map.put(state.jobs, job.id, tracked)
      }
      {:reply, {:ok, job.id}, dispatch_pending(new_state)}
    end
  end

  def handle_call({:status, job_id}, _from, state) do
    case Map.get(state.jobs, job_id) do
      nil -> {:reply, {:error, :not_found}, state}
      tracked -> {:reply, {:ok, tracked}, state}
    end
  end

  def handle_call(:depth, _from, state) do
    {:reply, :queue.len(state.queue), state}
  end

  @impl GenServer
  def handle_info({:job_done, job_id, result}, state) do
    updated_jobs = Map.update!(state.jobs, job_id, &%{&1 | status: :done, result: result})
    new_state = %{state | jobs: updated_jobs, active: max(state.active - 1, 0)}
    {:noreply, dispatch_pending(new_state)}
  end

  def handle_info({:job_failed, job_id, reason}, state) do
    updated_jobs = Map.update!(state.jobs, job_id, &%{&1 | status: :failed, result: reason})
    new_state = %{state | jobs: updated_jobs, active: max(state.active - 1, 0)}
    {:noreply, dispatch_pending(new_state)}
  end

  @spec dispatch_pending(state()) :: state()
  defp dispatch_pending(%{active: active, max_workers: max} = state) when active >= max, do: state

  defp dispatch_pending(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, job}, rest} ->
        caller = self()
        Task.start(fn -> TranscodeWorker.run(job, caller) end)
        updated_jobs = Map.update!(state.jobs, job.id, &%{&1 | status: :processing})
        dispatch_pending(%{state | queue: rest, jobs: updated_jobs, active: state.active + 1})
    end
  end

  @spec build_job(String.t(), String.t()) :: job()
  defp build_job(source_url, target_format) do
    %{
      id: generate_id(),
      source_url: source_url,
      target_format: target_format,
      submitted_at: DateTime.utc_now()
    }
  end

  @spec generate_id() :: String.t()
  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
end
```
