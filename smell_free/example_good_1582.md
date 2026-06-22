```elixir
defmodule CircuitBreaker.State do
  @moduledoc """
  Immutable value representing the current health state of a circuit.
  """

  @type status :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          status: status(),
          failure_count: non_neg_integer(),
          last_failure_at: integer() | nil,
          success_count: non_neg_integer()
        }

  defstruct status: :closed, failure_count: 0, last_failure_at: nil, success_count: 0
end

defmodule CircuitBreaker do
  use GenServer

  alias CircuitBreaker.State

  @moduledoc """
  A process-backed circuit breaker protecting calls to an external dependency.
  Opens after a configurable failure threshold, then moves to half-open after
  a recovery window to probe whether the dependency has recovered.
  """

  @type config :: %{
          failure_threshold: pos_integer(),
          recovery_window_ms: pos_integer(),
          half_open_successes_required: pos_integer()
        }

  @default_config %{
    failure_threshold: 5,
    recovery_window_ms: 30_000,
    half_open_successes_required: 2
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    config = Keyword.get(opts, :config, @default_config)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @spec call(GenServer.server(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, :circuit_open | term()}
  def call(server, function) when is_function(function, 0) do
    case GenServer.call(server, :check) do
      :allow ->
        result = function.()
        report(server, result)
        result

      :deny ->
        {:error, :circuit_open}
    end
  end

  @spec status(GenServer.server()) :: State.status()
  def status(server) do
    GenServer.call(server, :status)
  end

  @impl GenServer
  def init(config) do
    {:ok, %{config: config, state: %State{}}}
  end

  @impl GenServer
  def handle_call(:check, _from, %{state: circuit_state, config: config} = s) do
    {decision, new_circuit_state} = evaluate(circuit_state, config)
    {:reply, decision, %{s | state: new_circuit_state}}
  end

  def handle_call(:status, _from, %{state: circuit_state} = s) do
    {:reply, circuit_state.status, s}
  end

  def handle_call({:report, :ok}, _from, %{state: circuit_state, config: config} = s) do
    updated = record_success(circuit_state, config)
    {:reply, :ok, %{s | state: updated}}
  end

  def handle_call({:report, :error}, _from, %{state: circuit_state, config: config} = s) do
    updated = record_failure(circuit_state, config)
    {:reply, :ok, %{s | state: updated}}
  end

  defp report(server, {:ok, _}), do: GenServer.call(server, {:report, :ok})
  defp report(server, {:error, _}), do: GenServer.call(server, {:report, :error})

  defp evaluate(%State{status: :closed} = state, _config), do: {:allow, state}

  defp evaluate(%State{status: :open, last_failure_at: last} = state, config) do
    now = System.monotonic_time(:millisecond)

    if now - last >= config.recovery_window_ms do
      {:allow, %{state | status: :half_open, success_count: 0}}
    else
      {:deny, state}
    end
  end

  defp evaluate(%State{status: :half_open} = state, _config), do: {:allow, state}

  defp record_success(%State{status: :half_open} = state, config) do
    new_count = state.success_count + 1

    if new_count >= config.half_open_successes_required do
      %State{}
    else
      %{state | success_count: new_count}
    end
  end

  defp record_success(state, _config), do: state

  defp record_failure(state, config) do
    new_count = state.failure_count + 1
    now = System.monotonic_time(:millisecond)

    if new_count >= config.failure_threshold do
      %{state | status: :open, failure_count: new_count, last_failure_at: now}
    else
      %{state | failure_count: new_count, last_failure_at: now}
    end
  end
end
```
