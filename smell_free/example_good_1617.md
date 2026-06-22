```elixir
defmodule Resilience.CircuitBreaker do
  @moduledoc """
  GenServer implementing the circuit breaker pattern for external service calls.

  Tracks consecutive failures and transitions through :closed, :open, and
  :half_open states. Configuration is passed at startup via child spec options.
  """

  use GenServer

  require Logger

  alias Resilience.CircuitBreaker.{State, Config}

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes a zero-arity function through the circuit breaker.

  Returns `{:ok, result}` on success, `{:error, :circuit_open}` when tripped,
  or `{:error, reason}` when the function raises or returns an error.
  """
  @spec call(atom(), (() -> term())) :: {:ok, term()} | {:error, term()}
  def call(breaker_name, fun) when is_atom(breaker_name) and is_function(fun, 0) do
    GenServer.call(breaker_name, {:execute, fun})
  end

  @doc """
  Returns the current circuit state for inspection.
  """
  @spec status(atom()) :: :closed | :open | :half_open
  def status(breaker_name) when is_atom(breaker_name) do
    GenServer.call(breaker_name, :status)
  end

  @doc """
  Manually resets the breaker to the closed state.
  """
  @spec reset(atom()) :: :ok
  def reset(breaker_name) when is_atom(breaker_name) do
    GenServer.cast(breaker_name, :reset)
  end

  @impl GenServer
  def init(opts) do
    config = Config.from_opts(opts)
    {:ok, State.initial(config)}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state.circuit, state}
  end

  def handle_call({:execute, _fun}, _from, %State{circuit: :open} = state) do
    if State.probe_allowed?(state) do
      {:reply, {:error, :circuit_open}, State.transition_to_half_open(state)}
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:execute, fun}, _from, state) do
    {result, new_state} = run_protected(fun, state)
    {:reply, result, new_state}
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    {:noreply, State.reset(state)}
  end

  defp run_protected(fun, state) do
    result = fun.()
    {wrap_result(result), State.record_success(state)}
  rescue
    err ->
      Logger.warning("circuit breaker caught error: #{Exception.message(err)}")
      new_state = State.record_failure(state)
      {{:error, Exception.message(err)}, new_state}
  end

  defp wrap_result({:error, _} = err), do: err
  defp wrap_result({:ok, _} = ok), do: ok
  defp wrap_result(value), do: {:ok, value}
end

defmodule Resilience.CircuitBreaker.Config do
  @moduledoc false

  @enforce_keys [:failure_threshold, :recovery_timeout_ms]
  defstruct [:failure_threshold, :recovery_timeout_ms]

  @type t :: %__MODULE__{
          failure_threshold: pos_integer(),
          recovery_timeout_ms: pos_integer()
        }

  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    %__MODULE__{
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      recovery_timeout_ms: Keyword.get(opts, :recovery_timeout_ms, 30_000)
    }
  end
end

defmodule Resilience.CircuitBreaker.State do
  @moduledoc false

  alias Resilience.CircuitBreaker.Config

  defstruct [:config, :circuit, :failure_count, :opened_at]

  @type t :: %__MODULE__{
          config: Config.t(),
          circuit: :closed | :open | :half_open,
          failure_count: non_neg_integer(),
          opened_at: integer() | nil
        }

  @spec initial(Config.t()) :: t()
  def initial(config), do: %__MODULE__{config: config, circuit: :closed, failure_count: 0, opened_at: nil}

  @spec record_success(t()) :: t()
  def record_success(state), do: %{state | circuit: :closed, failure_count: 0, opened_at: nil}

  @spec record_failure(t()) :: t()
  def record_failure(%{failure_count: fc, config: %{failure_threshold: thresh}} = state) do
    new_count = fc + 1
    if new_count >= thresh, do: trip(state, new_count), else: %{state | failure_count: new_count}
  end

  @spec probe_allowed?(t()) :: boolean()
  def probe_allowed?(%{opened_at: opened_at, config: %{recovery_timeout_ms: timeout}}) do
    System.monotonic_time(:millisecond) - opened_at >= timeout
  end

  @spec transition_to_half_open(t()) :: t()
  def transition_to_half_open(state), do: %{state | circuit: :half_open}

  @spec reset(t()) :: t()
  def reset(state), do: %{state | circuit: :closed, failure_count: 0, opened_at: nil}

  defp trip(state, count) do
    %{state | circuit: :open, failure_count: count, opened_at: System.monotonic_time(:millisecond)}
  end
end
```
