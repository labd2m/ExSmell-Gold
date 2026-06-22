# File: `example_good_615.md`

```elixir
defmodule Infra.GracefulShutdown do
  @moduledoc """
  Coordinates graceful application shutdown by registering cleanup
  handlers that run in priority order before the node terminates.

  Handlers are registered with a priority (lower numbers run first)
  and a maximum duration. The coordinator runs each handler in sequence
  and enforces its time budget, logging overruns but not blocking
  subsequent handlers.

  Start this GenServer near the top of your supervision tree.
  """

  use GenServer

  require Logger

  @default_handler_timeout_ms 10_000
  @default_drain_timeout_ms 30_000

  @type priority :: non_neg_integer()
  @type handler_name :: String.t()
  @type handler_fn :: (-> :ok | {:error, term()})

  @type handler_spec :: %{
          required(:name) => handler_name(),
          required(:priority) => priority(),
          required(:run) => handler_fn(),
          optional(:timeout_ms) => pos_integer()
        }

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a shutdown handler.

  Handlers with lower priority values execute first. Multiple handlers
  may share the same priority; within a priority level order is undefined.
  """
  @spec register(handler_spec()) :: :ok | {:error, :already_registered}
  def register(%{name: name, priority: _, run: _} = spec) when is_binary(name) do
    GenServer.call(__MODULE__, {:register, spec})
  end

  @doc """
  Initiates the graceful shutdown sequence, running all handlers in
  priority order.

  Blocks until all handlers have completed or their individual timeouts
  have elapsed. Returns a summary of handler outcomes.
  """
  @spec initiate() :: [%{name: handler_name(), status: :ok | :error | :timeout}]
  def initiate do
    GenServer.call(__MODULE__, :initiate, @default_drain_timeout_ms + 5_000)
  end

  @doc """
  Returns all registered handler names sorted by priority.
  """
  @spec registered_handlers() :: [handler_spec()]
  def registered_handlers do
    GenServer.call(__MODULE__, :registered_handlers)
  end

  @impl GenServer
  def init(opts) do
    drain_timeout_ms = Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms)
    {:ok, %{handlers: [], drain_timeout_ms: drain_timeout_ms, shutting_down: false}}
  end

  @impl GenServer
  def handle_call({:register, spec}, _from, state) do
    if Enum.any?(state.handlers, &(&1.name == spec.name)) do
      {:reply, {:error, :already_registered}, state}
    else
      {:reply, :ok, %{state | handlers: [spec | state.handlers]}}
    end
  end

  @impl GenServer
  def handle_call(:initiate, _from, %{shutting_down: true} = state) do
    {:reply, [], state}
  end

  @impl GenServer
  def handle_call(:initiate, _from, state) do
    Logger.info("Graceful shutdown initiated — running #{length(state.handlers)} handler(s)")

    sorted_handlers =
      state.handlers
      |> Enum.sort_by(&{&1.priority, &1.name})

    results = Enum.map(sorted_handlers, &run_handler/1)

    {:reply, results, %{state | shutting_down: true}}
  end

  @impl GenServer
  def handle_call(:registered_handlers, _from, state) do
    sorted = Enum.sort_by(state.handlers, &{&1.priority, &1.name})
    {:reply, sorted, state}
  end

  defp run_handler(%{name: name, run: run_fn} = spec) do
    timeout_ms = Map.get(spec, :timeout_ms, @default_handler_timeout_ms)
    start_ms = System.monotonic_time(:millisecond)

    task = Task.async(fn ->
      try do
        run_fn.()
      rescue
        e -> {:error, Exception.message(e)}
      end
    end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        duration = System.monotonic_time(:millisecond) - start_ms
        Logger.info("Handler #{name} completed in #{duration}ms")
        %{name: name, status: :ok}

      {:ok, {:error, reason}} ->
        Logger.error("Handler #{name} failed: #{inspect(reason)}")
        %{name: name, status: :error}

      nil ->
        Logger.warning("Handler #{name} timed out after #{timeout_ms}ms")
        %{name: name, status: :timeout}
    end
  end
end
```
