```elixir
defmodule Ops.GracefulShutdown do
  @moduledoc """
  Coordinates a graceful application shutdown sequence. On receiving a
  SIGTERM signal the coordinator stops accepting new work, waits for
  in-flight tasks to drain within a configurable deadline, and then
  initiates the OTP application stop. Each drain step is registered as
  a named callback at runtime so modules can participate without coupling
  to this coordinator directly.
  """

  use GenServer

  require Logger

  @type drain_fn :: (-> :ok)
  @type step :: %{name: String.t(), drain_fn: drain_fn(), timeout_ms: pos_integer()}

  @default_drain_timeout_ms 30_000

  @doc "Starts the shutdown coordinator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a drain step to execute on shutdown."
  @spec register_step(String.t(), drain_fn(), pos_integer()) :: :ok
  def register_step(name, drain_fn, timeout_ms \ @default_drain_timeout_ms)
      when is_binary(name) and is_function(drain_fn, 0) and is_integer(timeout_ms) do
    GenServer.call(__MODULE__, {:register, name, drain_fn, timeout_ms})
  end

  @doc "Initiates the graceful shutdown sequence."
  @spec initiate() :: :ok
  def initiate, do: GenServer.cast(__MODULE__, :initiate)

  @doc "Returns the list of registered drain step names in execution order."
  @spec registered_steps() :: [String.t()]
  def registered_steps do
    GenServer.call(__MODULE__, :registered_steps)
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :trap_signals, true) do
      :os.set_signal(:sigterm, :handle)
    end

    {:ok, %{steps: [], shutting_down: false}}
  end

  @impl GenServer
  def handle_call({:register, name, drain_fn, timeout_ms}, _from, state) do
    step = %{name: name, drain_fn: drain_fn, timeout_ms: timeout_ms}
    {:reply, :ok, %{state | steps: state.steps ++ [step]}}
  end

  def handle_call(:registered_steps, _from, state) do
    {:reply, Enum.map(state.steps, & &1.name), state}
  end

  @impl GenServer
  def handle_cast(:initiate, %{shutting_down: true} = state) do
    {:noreply, state}
  end

  def handle_cast(:initiate, state) do
    Logger.info("[GracefulShutdown] Initiating shutdown sequence")
    new_state = %{state | shutting_down: true}
    send(self(), :run_drain)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:run_drain, %{steps: steps} = state) do
    run_drain_steps(steps)
    Logger.info("[GracefulShutdown] All drain steps complete, stopping application")
    :init.stop()
    {:noreply, state}
  end

  def handle_info({:signal, :sigterm}, state) do
    Logger.info("[GracefulShutdown] Received SIGTERM")
    send(self(), :run_drain)
    {:noreply, %{state | shutting_down: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_drain_steps(steps) do
    Enum.each(steps, fn %{name: name, drain_fn: drain_fn, timeout_ms: timeout} ->
      Logger.info("[GracefulShutdown] Draining: #{name}")
      task = Task.async(drain_fn)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, :ok} ->
          Logger.info("[GracefulShutdown] #{name} drained successfully")

        nil ->
          Logger.warning("[GracefulShutdown] #{name} timed out after #{timeout}ms")

        {:exit, reason} ->
          Logger.error("[GracefulShutdown] #{name} failed: #{inspect(reason)}")
      end
    end)
  end
end
```
