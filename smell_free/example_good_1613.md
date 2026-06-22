```elixir
defmodule App.GracefulShutdown do
  @moduledoc """
  Coordinates a graceful application shutdown sequence. On receiving a
  SIGTERM signal, drains in-flight work, flushes pending writes, deregisters
  from service discovery, and signals readiness to terminate.
  """

  use GenServer

  alias App.{WorkQueue, MetricsBuffer, ServiceRegistry}

  @drain_timeout_ms 25_000
  @flush_timeout_ms 5_000

  @type shutdown_step :: %{name: atom(), status: :pending | :complete | :failed, duration_ms: non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec initiate() :: {:ok, [shutdown_step()]} | {:error, term()}
  def initiate do
    GenServer.call(__MODULE__, :initiate, @drain_timeout_ms + @flush_timeout_ms + 10_000)
  end

  @spec status() :: :running | :draining | :shutdown
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{phase: :running, steps: []}}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state.phase, state}
  end

  def handle_call(:initiate, _from, %{phase: :running} = state) do
    steps = run_shutdown_sequence()
    {:reply, {:ok, steps}, %{state | phase: :shutdown, steps: steps}}
  end

  def handle_call(:initiate, _from, state) do
    {:reply, {:error, :already_shutting_down}, state}
  end

  @impl GenServer
  def handle_info(:EXIT, _from, state) do
    run_shutdown_sequence()
    {:stop, :normal, state}
  end

  @spec run_shutdown_sequence() :: [shutdown_step()]
  defp run_shutdown_sequence do
    [
      {&deregister_from_discovery/0, :deregister},
      {&drain_work_queue/0, :drain_queue},
      {&flush_metrics/0, :flush_metrics},
      {&close_db_connections/0, :close_db}
    ]
    |> Enum.map(fn {step_fn, step_name} -> execute_step(step_name, step_fn) end)
  end

  @spec execute_step(atom(), (-> :ok | {:error, term()})) :: shutdown_step()
  defp execute_step(name, fun) do
    start = System.monotonic_time(:millisecond)

    status =
      try do
        case fun.() do
          :ok -> :complete
          {:error, _} -> :failed
        end
      rescue
        _ -> :failed
      end

    duration = System.monotonic_time(:millisecond) - start
    %{name: name, status: status, duration_ms: duration}
  end

  @spec deregister_from_discovery() :: :ok | {:error, term()}
  defp deregister_from_discovery do
    ServiceRegistry.deregister(node())
  end

  @spec drain_work_queue() :: :ok | {:error, term()}
  defp drain_work_queue do
    WorkQueue.drain(timeout_ms: @drain_timeout_ms)
  end

  @spec flush_metrics() :: :ok | {:error, term()}
  defp flush_metrics do
    MetricsBuffer.flush(timeout_ms: @flush_timeout_ms)
  end

  @spec close_db_connections() :: :ok
  defp close_db_connections do
    Ecto.Adapters.SQL.Sandbox.checkin(App.Repo)
    :ok
  rescue
    _ -> :ok
  end
end
```
