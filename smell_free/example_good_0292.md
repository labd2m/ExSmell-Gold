```elixir
defmodule MyApp.Tasks.Supervisor do
  @moduledoc """
  The top-level OTP supervisor for all background task infrastructure.
  Arranges child processes in dependency order: the Registry and
  DynamicSupervisor must be running before any workers attempt to
  register themselves, so they are started first under a `:rest_for_one`
  strategy.

  The application supervisor starts this module as a single child,
  keeping the main supervision tree clean:

      children = [MyApp.Tasks.Supervisor]
  """

  use Supervisor

  @doc "Starts the task supervisor tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: MyApp.Tasks.Registry},
      {DynamicSupervisor,
       name: MyApp.Tasks.WorkerSupervisor,
       strategy: :one_for_one,
       max_children: 50},
      {Task.Supervisor, name: MyApp.Tasks.TaskSupervisor},
      MyApp.Tasks.Dispatcher,
      MyApp.Tasks.Monitor
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule MyApp.Tasks.Dispatcher do
  @moduledoc """
  Accepts task submissions and starts a supervised worker per task under
  `MyApp.Tasks.WorkerSupervisor`. Duplicate task IDs are rejected to
  prevent double-scheduling of idempotent background operations.
  """

  use GenServer

  alias MyApp.Tasks.Worker

  @doc "Starts the dispatcher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submits a task for execution. Returns `{:ok, pid}` or
  `{:error, :already_running}` when a task with the same ID is active.
  """
  @spec submit(%{required(:id) => String.t(), required(:type) => atom(), optional(atom()) => term()}) ::
          {:ok, pid()} | {:error, :already_running} | {:error, term()}
  def submit(%{id: id} = task) when is_binary(id) do
    GenServer.call(__MODULE__, {:submit, task})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:submit, task}, _from, state) do
    result =
      case Registry.lookup(MyApp.Tasks.Registry, task.id) do
        [{_pid, _}] ->
          {:error, :already_running}

        [] ->
          DynamicSupervisor.start_child(
            MyApp.Tasks.WorkerSupervisor,
            {Worker, task}
          )
      end

    {:reply, result, state}
  end
end

defmodule MyApp.Tasks.Monitor do
  @moduledoc """
  Emits telemetry events as tasks complete or crash, providing visibility
  into task throughput and error rates without coupling workers to
  observability concerns.
  """

  use GenServer

  require Logger

  @impl true
  def init(_opts) do
    :ok = :net_kernel.monitor_nodes(false)
    {:ok, %{}}
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    emit(:completed)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, :process, _pid, reason}, state) when reason != :normal do
    Logger.warning("task_worker_crashed", reason: inspect(reason))
    emit(:failed)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @spec emit(atom()) :: :ok
  defp emit(outcome) do
    :telemetry.execute([:my_app, :tasks, :worker], %{count: 1}, %{outcome: outcome})
  end
end
```
