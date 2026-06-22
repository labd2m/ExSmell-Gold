```elixir
defmodule Mediaflow.Transcoder.Pool do
  @moduledoc """
  Dynamic supervisor that manages a bounded pool of stateless transcoding workers.

  Workers are started on demand and terminated after completing their job.
  The pool enforces a concurrency ceiling to prevent system overload.
  """

  use DynamicSupervisor

  alias Mediaflow.Transcoder.Worker

  @max_concurrency 8

  @type job :: %{
          asset_id: String.t(),
          source_url: String.t(),
          target_codec: String.t(),
          notify_pid: pid()
        }

  @doc false
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_concurrency)
  end

  @doc """
  Enqueues a transcoding job by starting a transient worker child.

  Returns `{:ok, pid}` if a worker slot is available, or
  `{:error, :max_children}` when the pool is at capacity.
  """
  @spec submit(job()) :: {:ok, pid()} | {:error, :max_children | term()}
  def submit(%{asset_id: id, source_url: url, target_codec: codec, notify_pid: pid} = job)
      when is_binary(id) and is_binary(url) and is_binary(codec) and is_pid(pid) do
    child_spec = Worker.child_spec(job)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def submit(_), do: {:error, :invalid_job}

  @doc """
  Returns the count of currently running transcoding workers.
  """
  @spec running_count() :: non_neg_integer()
  def running_count do
    %{workers: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end
end

defmodule Mediaflow.Transcoder.Worker do
  @moduledoc """
  Transient GenServer that executes a single transcoding job and notifies the caller.
  """

  use GenServer, restart: :transient

  alias Mediaflow.Transcoder.FFmpegAdapter

  @doc false
  def child_spec(job) do
    %{
      id: {__MODULE__, job.asset_id},
      start: {__MODULE__, :start_link, [job]},
      restart: :transient,
      type: :worker
    }
  end

  @doc false
  def start_link(job) do
    GenServer.start_link(__MODULE__, job)
  end

  @impl GenServer
  def init(job) do
    {:ok, job, {:continue, :run}}
  end

  @impl GenServer
  def handle_continue(:run, job) do
    result = FFmpegAdapter.transcode(job.source_url, job.target_codec)
    send(job.notify_pid, {:transcode_result, job.asset_id, result})
    {:stop, :normal, job}
  end
end
```
