**File:** `example_good_1177.md`

```elixir
defmodule CircuitBreaker.State do
  @moduledoc "Represents the internal state of a single circuit breaker instance."

  @enforce_keys [:name, :failure_threshold, :recovery_timeout_ms, :status]
  defstruct [
    :name,
    :failure_threshold,
    :recovery_timeout_ms,
    status: :closed,
    failure_count: 0,
    last_failure_at: nil,
    success_count: 0
  ]

  @type status :: :closed | :open | :half_open
  @type t :: %__MODULE__{
          name: String.t(),
          failure_threshold: pos_integer(),
          recovery_timeout_ms: pos_integer(),
          status: status(),
          failure_count: non_neg_integer(),
          last_failure_at: integer() | nil,
          success_count: non_neg_integer()
        }
end

defmodule CircuitBreaker do
  @moduledoc """
  A GenServer implementing the circuit breaker pattern for protecting
  against cascading failures when calling external services.

  States:
  - `:closed`    — normal operation, calls pass through
  - `:open`      — tripping threshold exceeded, calls rejected immediately
  - `:half_open` — recovery probe window, one call allowed through
  """

  use GenServer

  alias CircuitBreaker.State

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @spec call(String.t(), (-> term())) :: {:ok, term()} | {:error, :circuit_open} | {:error, term()}
  def call(name, func) when is_binary(name) and is_function(func, 0) do
    GenServer.call(via(name), {:call, func})
  end

  @spec status(String.t()) :: State.status()
  def status(name) when is_binary(name) do
    GenServer.call(via(name), :status)
  end

  @spec reset(String.t()) :: :ok
  def reset(name) when is_binary(name) do
    GenServer.call(via(name), :reset)
  end

  @impl GenServer
  def init(opts) do
    state = %State{
      name: Keyword.fetch!(opts, :name),
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      recovery_timeout_ms: Keyword.get(opts, :recovery_timeout_ms, :timer.seconds(30)),
      status: :closed
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:call, func}, _from, %State{status: :open} = state) do
    if recovery_timeout_elapsed?(state) do
      attempt_probe(func, %{state | status: :half_open})
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:call, func}, _from, %State{status: status} = state)
      when status in [:closed, :half_open] do
    attempt_probe(func, state)
  end

  def handle_call(:status, _from, state) do
    effective_status = if state.status == :open and recovery_timeout_elapsed?(state),
      do: :half_open,
      else: state.status

    {:reply, effective_status, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | status: :closed, failure_count: 0, last_failure_at: nil, success_count: 0}}
  end

  defp attempt_probe(func, state) do
    result = safe_call(func)
    new_state = transition(state, result)
    {:reply, result, new_state}
  end

  defp safe_call(func) do
    {:ok, func.()}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp transition(%State{} = state, {:ok, _}) do
    %{state | status: :closed, failure_count: 0, last_failure_at: nil, success_count: state.success_count + 1}
  end

  defp transition(%State{failure_count: count, failure_threshold: threshold} = state, {:error, _}) do
    new_count = count + 1
    new_status = if new_count >= threshold, do: :open, else: state.status

    %{state | status: new_status, failure_count: new_count, last_failure_at: System.monotonic_time(:millisecond)}
  end

  defp recovery_timeout_elapsed?(%State{last_failure_at: nil}), do: false

  defp recovery_timeout_elapsed?(%State{last_failure_at: ts, recovery_timeout_ms: timeout}) do
    System.monotonic_time(:millisecond) - ts >= timeout
  end

  defp via(name), do: {:via, Registry, {CircuitBreaker.Registry, name}}
end

defmodule CircuitBreaker.Supervisor do
  @moduledoc "Supervises circuit breaker instances and their registry."

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: CircuitBreaker.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
