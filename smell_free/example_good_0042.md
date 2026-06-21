```elixir
defmodule Workforce.JobSupervisor do
  @moduledoc """
  Manages a bounded pool of transient job workers using a DynamicSupervisor.
  Each job runs in its own isolated GenServer process. On failure the worker
  terminates without automatic restart; callers may re-dispatch if needed.
  """

  use DynamicSupervisor

  alias Workforce.JobWorker

  @type priority :: :low | :normal | :high
  @type job :: %{id: String.t(), payload: term(), priority: priority()}

  @doc """
  Starts the supervisor and registers it under its module name.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatches a new worker for the given `job`. Returns the worker PID on
  success, or an error if the pool is at capacity or the job ID is already active.
  """
  @spec dispatch(job()) :: {:ok, pid()} | {:error, :at_capacity | :already_running}
  def dispatch(%{id: id, priority: priority} = job)
      when is_binary(id) and priority in [:low, :normal, :high] do
    case DynamicSupervisor.start_child(__MODULE__, {JobWorker, job}) do
      {:ok, pid} -> {:ok, pid}
      {:error, :max_children} -> {:error, :at_capacity}
      {:error, {:already_started, _}} -> {:error, :already_running}
      {:error, _} -> {:error, :at_capacity}
    end
  end

  @doc """
  Returns the count of currently active worker processes.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 200)
  end
end

defmodule Workforce.JobWorker do
  @moduledoc """
  A transient GenServer that executes one job then terminates normally.
  High-priority jobs begin immediately; lower-priority jobs receive a
  startup delay so higher-priority work can proceed first.
  """

  use GenServer

  require Logger

  @startup_delay_ms %{high: 0, normal: 300, low: 1_000}

  @type state :: %{
          id: String.t(),
          payload: term(),
          priority: Workforce.JobSupervisor.priority()
        }

  @doc false
  @spec start_link(Workforce.JobSupervisor.job()) :: GenServer.on_start()
  def start_link(%{id: _id} = job) do
    GenServer.start_link(__MODULE__, job)
  end

  @impl GenServer
  def init(%{priority: priority} = job) do
    delay = Map.get(@startup_delay_ms, priority, 0)
    Process.send_after(self(), :run, delay)
    {:ok, job}
  end

  @impl GenServer
  def handle_info(:run, %{id: id, payload: payload} = state) do
    case execute(payload) do
      :ok ->
        Logger.info("[Workforce] Job #{id} completed")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("[Workforce] Job #{id} failed: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, state}
    end
  end

  defp execute(payload) when is_map(payload), do: :ok
  defp execute(payload) when is_binary(payload), do: :ok
  defp execute(_), do: {:error, :unsupported_payload}
end
```
