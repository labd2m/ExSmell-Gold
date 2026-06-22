```elixir
defmodule MyApp.Infra.GracefulShutdown do
  @moduledoc """
  Coordinates an orderly application shutdown by draining in-flight work
  before the BEAM process exits. Registered drainers are called in
  reverse registration order (LIFO), allowing dependent subsystems to
  shut down after their dependencies.

  Install the signal handler once at application start:

      MyApp.Infra.GracefulShutdown.install()

  Register drainers from any supervised process:

      MyApp.Infra.GracefulShutdown.register(:oban, fn ->
        Oban.drain_queue(queue: :default)
      end)
  """

  use GenServer

  require Logger

  @drain_timeout_ms 30_000

  @type drainer_name :: atom()
  @type drainer_fn :: (-> :ok | {:error, term()})

  @doc "Starts the graceful shutdown coordinator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Installs SIGTERM and SIGINT handlers that trigger graceful shutdown
  instead of abrupt termination.
  """
  @spec install() :: :ok
  def install do
    :os.set_signal(:sigterm, :handle)
    :os.set_signal(:sigint, :handle)
    :ok
  end

  @doc "Registers a named drainer function called during shutdown."
  @spec register(drainer_name(), drainer_fn()) :: :ok
  def register(name, fun) when is_atom(name) and is_function(fun, 0) do
    GenServer.call(__MODULE__, {:register, name, fun})
  end

  @doc "Triggers an immediate graceful shutdown sequence."
  @spec initiate() :: :ok
  def initiate do
    GenServer.cast(__MODULE__, :shutdown)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{drainers: []}}
  end

  @impl GenServer
  def handle_call({:register, name, fun}, _from, state) do
    {:reply, :ok, %{state | drainers: [{name, fun} | state.drainers]}}
  end

  @impl GenServer
  def handle_cast(:shutdown, state) do
    Logger.info("graceful_shutdown_started", drainer_count: length(state.drainers))
    run_drainers(state.drainers)
    Logger.info("graceful_shutdown_complete")
    System.stop(0)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:signal, signal}, state) when signal in [:sigterm, :sigint] do
    Logger.info("shutdown_signal_received", signal: signal)
    GenServer.cast(self(), :shutdown)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @spec run_drainers([{drainer_name(), drainer_fn()}]) :: :ok
  defp run_drainers(drainers) do
    Enum.each(drainers, fn {name, fun} ->
      Logger.info("drainer_starting", name: name)
      start_ms = System.monotonic_time(:millisecond)

      task = Task.async(fun)

      case Task.yield(task, @drain_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, :ok} ->
          duration_ms = System.monotonic_time(:millisecond) - start_ms
          Logger.info("drainer_finished", name: name, duration_ms: duration_ms)

        {:ok, {:error, reason}} ->
          Logger.error("drainer_failed", name: name, reason: inspect(reason))

        nil ->
          Logger.error("drainer_timeout", name: name, timeout_ms: @drain_timeout_ms)
      end
    end)
  end
end
```
