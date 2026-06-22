```elixir
defmodule Media.TranscodeRegistry do
  @moduledoc """
  Registry and supervisor for per-asset transcoding jobs.

  Each asset gets at most one active transcoding process. Attempting to start
  a duplicate job returns the existing PID. Job status is queryable at any time.
  """

  use DynamicSupervisor

  alias Media.TranscodeRegistry.{Worker, StatusStore}

  @doc false
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Starts a transcoding job for the given asset, unless one is already running.

  Returns `{:ok, pid}` for a new job or `{:already_running, pid}` for an existing one.
  """
  @spec start_job(String.t(), map()) :: {:ok, pid()} | {:already_running, pid()} | {:error, term()}
  def start_job(asset_id, params) when is_binary(asset_id) and is_map(params) do
    case find_existing(asset_id) do
      {:ok, pid} ->
        {:already_running, pid}

      :not_found ->
        spec = Worker.child_spec(%{asset_id: asset_id, params: params})
        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} ->
            StatusStore.record_started(asset_id, pid)
            {:ok, pid}
          error -> error
        end
    end
  end

  @doc """
  Returns the current status of a transcoding job.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(asset_id) when is_binary(asset_id) do
    StatusStore.fetch(asset_id)
  end

  @doc """
  Cancels a running transcoding job if one exists for the asset.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(asset_id) when is_binary(asset_id) do
    case find_existing(asset_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        StatusStore.record_cancelled(asset_id)
        :ok

      :not_found ->
        {:error, :not_found}
    end
  end

  defp find_existing(asset_id) do
    case StatusStore.fetch_pid(asset_id) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :not_found

      _ ->
        :not_found
    end
  end
end

defmodule Media.TranscodeRegistry.Worker do
  @moduledoc false

  use GenServer, restart: :transient

  alias Media.TranscodeRegistry.StatusStore
  alias Media.TranscodeRegistry.FFmpegRunner

  def child_spec(%{asset_id: id} = args) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [args]}, restart: :transient}
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl GenServer
  def init(%{asset_id: id, params: params} = state) do
    {:ok, state, {:continue, :transcode}}
  end

  @impl GenServer
  def handle_continue(:transcode, %{asset_id: id, params: params} = state) do
    StatusStore.record_progress(id, :running, 0)

    result = FFmpegRunner.run(params, fn pct ->
      StatusStore.record_progress(id, :running, pct)
    end)

    case result do
      {:ok, output_url} ->
        StatusStore.record_complete(id, output_url)

      {:error, reason} ->
        StatusStore.record_failed(id, reason)
    end

    {:stop, :normal, state}
  end
end

defmodule Media.TranscodeRegistry.StatusStore do
  @moduledoc false

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def record_started(asset_id, pid) do
    Agent.update(__MODULE__, &Map.put(&1, asset_id, %{status: :started, pid: pid, progress: 0}))
  end

  def record_progress(asset_id, status, pct) do
    Agent.update(__MODULE__, fn store ->
      Map.update(store, asset_id, %{}, &Map.merge(&1, %{status: status, progress: pct}))
    end)
  end

  def record_complete(asset_id, url) do
    Agent.update(__MODULE__, fn store ->
      Map.update(store, asset_id, %{}, &Map.merge(&1, %{status: :complete, output_url: url, progress: 100}))
    end)
  end

  def record_failed(asset_id, reason) do
    Agent.update(__MODULE__, fn store ->
      Map.update(store, asset_id, %{}, &Map.merge(&1, %{status: :failed, error: reason}))
    end)
  end

  def record_cancelled(asset_id) do
    Agent.update(__MODULE__, fn store ->
      Map.update(store, asset_id, %{}, &Map.put(&1, :status, :cancelled))
    end)
  end

  def fetch(asset_id) do
    Agent.get(__MODULE__, fn store ->
      case Map.fetch(store, asset_id) do
        {:ok, info} -> {:ok, info}
        :error -> {:error, :not_found}
      end
    end)
  end

  def fetch_pid(asset_id) do
    Agent.get(__MODULE__, fn store ->
      case Map.fetch(store, asset_id) do
        {:ok, %{pid: pid}} -> {:ok, pid}
        _ -> {:error, :not_found}
      end
    end)
  end
end
```
