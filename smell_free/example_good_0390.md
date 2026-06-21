```elixir
defmodule Infrastructure.GracefulShutdown do
  @moduledoc """
  Coordinates an orderly shutdown sequence when the BEAM node is asked to
  stop. The handler registers an `:init` termination callback, waits for
  in-flight requests to drain, flushes pending Oban jobs to the database,
  and closes external connections before allowing the VM to exit.

  The sequence is:
    1. Signal all registered drainable processes to stop accepting new work.
    2. Wait up to `:drain_timeout_ms` for them to finish current work.
    3. Flush Oban queues so jobs survive the restart.
    4. Run any registered finalizer functions (e.g., close Kafka producers).
    5. Allow the BEAM to proceed with normal OTP shutdown.
  """

  use GenServer

  require Logger

  @type finalizer :: (() -> :ok)

  @default_drain_timeout_ms 15_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a process that implements the drain protocol. On shutdown,
  `drain_fn` is called and the handler waits for `pid` to terminate.
  """
  @spec register_drainable(pid(), (() -> :ok)) :: :ok
  def register_drainable(pid, drain_fn) when is_pid(pid) and is_function(drain_fn, 0) do
    GenServer.cast(__MODULE__, {:register_drainable, pid, drain_fn})
  end

  @doc """
  Registers a zero-arity finalizer to be called at the end of shutdown.
  Finalizers run sequentially in registration order.
  """
  @spec register_finalizer(finalizer()) :: :ok
  def register_finalizer(fun) when is_function(fun, 0) do
    GenServer.cast(__MODULE__, {:register_finalizer, fun})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    drain_timeout = Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms)
    :init.notify_when_started(:kernel)

    state = %{
      drainables: [],
      finalizers: [],
      drain_timeout_ms: drain_timeout
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:register_drainable, pid, drain_fn}, state) do
    Process.monitor(pid)
    entry = %{pid: pid, drain_fn: drain_fn}
    {:noreply, %{state | drainables: [entry | state.drainables]}}
  end

  def handle_cast({:register_finalizer, fun}, state) do
    {:noreply, %{state | finalizers: state.finalizers ++ [fun]}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    updated = Enum.reject(state.drainables, &(&1.pid == pid))
    {:noreply, %{state | drainables: updated}}
  end

  def handle_info(:shutdown, state) do
    Logger.info("Graceful shutdown initiated",
      drainable_count: length(state.drainables),
      finalizer_count: length(state.finalizers)
    )

    drain_all(state.drainables, state.drain_timeout_ms)
    flush_oban()
    run_finalizers(state.finalizers)

    Logger.info("Graceful shutdown complete")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp drain_all([], _timeout), do: :ok

  defp drain_all(drainables, timeout_ms) do
    Enum.each(drainables, fn %{drain_fn: fun} ->
      Task.start(fun)
    end)

    pids = Enum.map(drainables, & &1.pid)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_pids(pids, deadline)
  end

  defp wait_for_pids([], _deadline), do: :ok

  defp wait_for_pids(pids, deadline) do
    remaining = System.monotonic_time(:millisecond)

    if remaining > deadline do
      Logger.warning("Drain timeout exceeded; forcing shutdown", remaining_pids: length(pids))
      :ok
    else
      Process.sleep(100)
      alive = Enum.filter(pids, &Process.alive?/1)
      wait_for_pids(alive, deadline)
    end
  end

  defp flush_oban do
    Logger.info("Flushing Oban queues")
    :ok = Oban.drain_queue(queue: :default)
  rescue
    e -> Logger.warning("Oban flush failed", reason: Exception.message(e))
  end

  defp run_finalizers(finalizers) do
    Enum.each(finalizers, fn fun ->
      try do
        fun.()
      rescue
        e -> Logger.error("Finalizer failed", reason: Exception.message(e))
      end
    end)
  end
end
```
