```elixir
defmodule Resilience.CircuitBreaker do
  @moduledoc """
  GenServer implementing the circuit breaker pattern for protecting
  downstream service calls. Transitions between :closed, :open, and
  :half_open states based on configurable failure thresholds and
  recovery windows.
  """

  use GenServer

  @type circuit_state :: :closed | :open | :half_open
  @type state :: %{
          name: atom(),
          circuit: circuit_state(),
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          failure_threshold: pos_integer(),
          success_threshold: pos_integer(),
          reset_timeout_ms: pos_integer(),
          opened_at: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec call(atom(), (() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, :circuit_open | term()}
  def call(name, fun) when is_atom(name) and is_function(fun, 0) do
    case GenServer.call(name, :request_permission) do
      :allowed ->
        result = execute_safely(fun)
        GenServer.cast(name, {:record_result, result})
        result

      :denied ->
        {:error, :circuit_open}
    end
  end

  @spec status(atom()) :: circuit_state()
  def status(name) when is_atom(name) do
    GenServer.call(name, :status)
  end

  @spec reset(atom()) :: :ok
  def reset(name) when is_atom(name) do
    GenServer.cast(name, :reset)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      circuit: :closed,
      failure_count: 0,
      success_count: 0,
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      success_threshold: Keyword.get(opts, :success_threshold, 2),
      reset_timeout_ms: Keyword.get(opts, :reset_timeout_ms, 30_000),
      opened_at: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:request_permission, _from, %{circuit: :closed} = state) do
    {:reply, :allowed, state}
  end

  def handle_call(:request_permission, _from, %{circuit: :open} = state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.opened_at

    if elapsed >= state.reset_timeout_ms do
      {:reply, :allowed, %{state | circuit: :half_open, success_count: 0}}
    else
      {:reply, :denied, state}
    end
  end

  def handle_call(:request_permission, _from, %{circuit: :half_open} = state) do
    {:reply, :allowed, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.circuit, state}
  end

  @impl GenServer
  def handle_cast({:record_result, {:ok, _}}, state) do
    {:noreply, record_success(state)}
  end

  def handle_cast({:record_result, {:error, _}}, state) do
    {:noreply, record_failure(state)}
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | circuit: :closed, failure_count: 0, success_count: 0, opened_at: nil}}
  end

  @spec record_success(state()) :: state()
  defp record_success(%{circuit: :half_open, success_count: count, success_threshold: threshold} = state)
       when count + 1 >= threshold do
    emit_transition(:half_open, :closed, state.name)
    %{state | circuit: :closed, failure_count: 0, success_count: 0, opened_at: nil}
  end

  defp record_success(%{circuit: :half_open} = state) do
    %{state | success_count: state.success_count + 1}
  end

  defp record_success(%{circuit: :closed} = state) do
    %{state | failure_count: 0}
  end

  @spec record_failure(state()) :: state()
  defp record_failure(%{circuit: :half_open} = state) do
    emit_transition(:half_open, :open, state.name)
    %{state | circuit: :open, opened_at: System.monotonic_time(:millisecond)}
  end

  defp record_failure(%{circuit: :closed, failure_count: count, failure_threshold: threshold} = state)
       when count + 1 >= threshold do
    emit_transition(:closed, :open, state.name)
    %{state | circuit: :open, failure_count: count + 1, opened_at: System.monotonic_time(:millisecond)}
  end

  defp record_failure(%{circuit: :closed} = state) do
    %{state | failure_count: state.failure_count + 1}
  end

  @spec execute_safely((() -> term())) :: {:ok, term()} | {:error, term()}
  defp execute_safely(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec emit_transition(circuit_state(), circuit_state(), atom()) :: :ok
  defp emit_transition(from, to, name) do
    :telemetry.execute(
      [:resilience, :circuit_breaker, :transition],
      %{},
      %{name: name, from: from, to: to}
    )
  end
end

defmodule Resilience.CircuitBreakerSupervisor do
  @moduledoc """
  Supervisor for a named set of circuit breaker processes.
  Each breaker protects a distinct downstream dependency.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    breakers = Keyword.get(opts, :breakers, [])

    children =
      Enum.map(breakers, fn breaker_opts ->
        name = Keyword.fetch!(breaker_opts, :name)
        Supervisor.child_spec({Resilience.CircuitBreaker, breaker_opts}, id: name)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
